import Foundation
import VoxaCore

/// Checks a tool call's arguments against the tool's own JSON Schema before anything reads them.
///
/// The API doesn't enforce `additionalProperties: false` or `enum` on a tool's input, so without this check a model can
/// pass arguments the schema forbids: an extra `"confirmed": true`, a number where text belongs, an enum value the tool
/// never handled. Rejecting them here means the code that runs sees exactly the shape the schema promised, and the model
/// gets a precise message to correct itself with.
public enum InputValidator {
    /// Bigger than any real tool call; a runaway argument is refused rather than processed.
    public static let maxInputBytes = 100_000

    /// The problems with `value`, in plain words for the model. Empty means the input matches the schema.
    public static func validate(_ value: JSONValue, against schema: JSONValue) -> [String] {
        if value.serialized().utf8.count > maxInputBytes {
            return ["The arguments are too large (over \(maxInputBytes / 1000) KB)."]
        }
        var problems: [String] = []
        check(value, schema: schema, path: [], into: &problems)
        return problems
    }

    private static func check(_ value: JSONValue, schema: JSONValue, path: [String], into problems: inout [String]) {
        guard case .object = schema else { return }
        let name = describe(path)

        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            problems.append("\(name) must be \(article(type)) \(type).")
            return
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            let list = allowed.compactMap(\.stringValue).joined(separator: ", ")
            problems.append("\(name) must be one of: \(list).")
            return
        }

        switch value {
        case .string(let text):
            if let minimum = schema["minLength"]?.intValue, text.count < minimum {
                problems.append("\(name) must be at least \(minimum) character\(minimum == 1 ? "" : "s") long.")
            }
            if let maximum = schema["maxLength"]?.intValue, text.count > maximum {
                problems.append("\(name) must be at most \(maximum) characters long.")
            }
        case .int, .double:
            let number = value.doubleValue ?? 0
            if let minimum = schema["minimum"]?.doubleValue, number < minimum {
                problems.append("\(name) must be at least \(format(minimum)).")
            }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum {
                problems.append("\(name) must be at most \(format(maximum)).")
            }
        case .array(let items):
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    check(item, schema: itemSchema, path: path + ["[\(index)]"], into: &problems)
                }
            }
            if let minimum = schema["minItems"]?.intValue, items.count < minimum {
                problems.append("\(name) needs at least \(minimum) item\(minimum == 1 ? "" : "s").")
            }
            if let maximum = schema["maxItems"]?.intValue, items.count > maximum {
                problems.append("\(name) can have at most \(maximum) items.")
            }
        case .object(let fields):
            checkObject(fields, schema: schema, path: path, into: &problems)
        case .null, .bool:
            break
        }
    }

    private static func checkObject(
        _ fields: [String: JSONValue],
        schema: JSONValue,
        path: [String],
        into problems: inout [String]
    ) {
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []

        for key in required where fields[key] == nil {
            problems.append("Missing required argument \(quoted(path + [key])).")
        }
        if schema["additionalProperties"] == false {
            let unexpected = fields.keys.filter { properties[$0] == nil }.sorted()
            if !unexpected.isEmpty {
                let names = unexpected.map { "'\($0)'" }.joined(separator: ", ")
                let allowed = properties.keys.sorted().joined(separator: ", ")
                problems.append(
                    "Unexpected argument\(unexpected.count == 1 ? "" : "s") \(names). "
                        + (allowed.isEmpty ? "This tool takes no arguments." : "The arguments are: \(allowed).")
                )
            }
        }
        for (key, propertySchema) in properties.sorted(by: { $0.key < $1.key }) {
            if let child = fields[key] {
                check(child, schema: propertySchema, path: path + [key], into: &problems)
            }
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object), ("null", .null): true
        case ("integer", .int): true
        case ("integer", .double(let number)): number == number.rounded() && abs(number) < 1e15
        case ("number", .int), ("number", .double): true
        default: false
        }
    }

    private static func describe(_ path: [String]) -> String {
        path.isEmpty ? "The arguments" : "Argument \(quoted(path))"
    }

    /// `'inner.x'` or `'tags[1]'`.
    private static func quoted(_ path: [String]) -> String {
        "'" + path.joined(separator: ".").replacingOccurrences(of: ".[", with: "[") + "'"
    }

    private static func article(_ type: String) -> String {
        type == "integer" || type == "object" || type == "array" ? "an" : "a"
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}
