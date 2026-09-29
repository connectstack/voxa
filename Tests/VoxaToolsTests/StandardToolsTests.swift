import Foundation
import Testing
import VoxaAgent
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

/// Builds the smallest input a schema accepts, so each tool's schema can be checked against its own `Decodable` input type.
private func sample(from schema: JSONValue) -> JSONValue {
    switch schema["type"]?.stringValue {
    case "string":
        if let first = schema["enum"]?.arrayValue?.first { return first }
        return .string("Safari")
    case "integer": return .int(schema["minimum"]?.intValue ?? 1)
    case "number": return .double(1)
    case "boolean": return true
    case "array": return .array([])
    case "object":
        var object: [String: JSONValue] = [:]
        let properties = schema["properties"]?.objectValue ?? [:]
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            object[key] = sample(from: properties[key] ?? [:])
        }
        return .object(object)
    default: return .null
    }
}

@Suite("Standard tools")
struct StandardToolsTests {
    private let tools = StandardTools.make(
        catalog: FakeAppCatalog.standard,
        opener: FakeOpener(),
        runner: FakeProcessRunner(returning: ProcessOutput(status: 0))
    )

    @Test("names are unique, sorted definitions can be built, and every tool has a real description")
    func definitions() {
        let names = tools.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(names) == ["open_app", "open_url", "list_shortcuts", "run_shortcut", "run_applescript"])
        for tool in tools {
            #expect(tool.summary.count > 60, "\(tool.name)'s description should say when to use it")
            #expect(tool.definition.name == tool.name)
        }
        #expect(ToolRegistry([]).definitions().isEmpty)
    }

    @Test("every schema is a closed object: the model can't pass arguments the tool doesn't declare")
    func closedSchemas() {
        for tool in tools {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
            #expect(tool.inputSchema["additionalProperties"] == false, "\(tool.name)")
        }
    }

    @Test("a minimal input built from each schema passes validation and decodes into the tool's own input type")
    func schemasMatchInputTypes() throws {
        for tool in tools {
            let input = sample(from: tool.inputSchema)
            #expect(InputValidator.validate(input, against: tool.inputSchema).isEmpty, "\(tool.name): \(input)")
            do {
                _ = try tool.assess(input)
            } catch let error as ToolInputError {
                Issue.record("\(tool.name) rejected the sample its own schema produced: \(error.message)")
            }
        }
    }

    @Test("the declared risk matches the tool's nature")
    func risks() {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.baselineRisk) })
        #expect(byName["open_app"] == .reversible)
        #expect(byName["open_url"] == .reversible)
        #expect(byName["list_shortcuts"] == .readOnly)
        #expect(byName["run_shortcut"] == .sensitive)
        #expect(byName["run_applescript"] == .sensitive)
        // The policy floor must agree with the tools that can do damage.
        #expect(PolicyFloors.floor(for: "run_shortcut") == .sensitive)
        #expect(PolicyFloors.floor(for: "run_applescript") == .sensitive)
    }

    @Test("no tool takes a shell command, and none is named like one")
    func noShell() {
        for tool in tools {
            #expect(!tool.name.contains("shell") && !tool.name.contains("exec") && !tool.name.contains("bash"))
            let properties = tool.inputSchema["properties"]?.objectValue?.keys.sorted() ?? []
            for key in properties {
                #expect(
                    !["command", "cmd", "shell", "bash", "exec"].contains(key),
                    "\(tool.name) has an argument named \(key)"
                )
            }
        }
    }
}
