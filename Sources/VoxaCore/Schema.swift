import Foundation

/// A tiny builder for the JSON Schema fragments tool inputs need. Schemas are data, so tests can compare them, and a
/// schema that disagrees with its `Decodable` input type is caught by a test instead of by the model at runtime.
public enum Schema {
    public static func string(
        _ description: String,
        enum values: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        if let minLength { schema["minLength"] = .int(minLength) }
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        return .object(schema)
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    public static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func array(of items: JSONValue, _ description: String) -> JSONValue {
        ["type": "array", "items": items, "description": .string(description)]
    }

    /// An object schema. `additionalProperties` is false so the model can't smuggle extra arguments.
    public static func object(
        _ properties: KeyValuePairs<String, JSONValue>,
        required: [String] = []
    ) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (key, value) in properties {
            props[key] = value
        }
        return [
            "type": "object",
            "properties": .object(props),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }
}
