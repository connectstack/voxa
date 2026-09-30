import Foundation
import Testing
import VoxaAgent
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

/// Builds the smallest input a schema accepts, so each tool's schema can be checked against its own `Decodable` input type.
/// Arguments that are dates get a date, since a schema can't say so.
private func sample(from schema: JSONValue, key: String? = nil) -> JSONValue {
    switch schema["type"]?.stringValue {
    case "string":
        if let first = schema["enum"]?.arrayValue?.first { return first }
        if let key, ["start", "end", "due", "new_start", "new_end"].contains(key) { return "2026-10-03T09:00:00+05:30" }
        return .string("Safari")
    case "integer": return .int(schema["minimum"]?.intValue ?? 1)
    case "number": return .double(1)
    case "boolean": return true
    case "array":
        let count = schema["minItems"]?.intValue ?? 0
        return .array((0..<count).map { _ in sample(from: schema["items"] ?? [:], key: key) })
    case "object":
        var object: [String: JSONValue] = [:]
        let properties = schema["properties"]?.objectValue ?? [:]
        for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            object[name] = sample(from: properties[name] ?? [:], key: name)
        }
        return .object(object)
    default: return .null
    }
}

/// Messages a tool gives when it could not *read* the arguments, as opposed to declining what they ask for.
private func isReadingProblem(_ message: String) -> Bool {
    message.hasPrefix("Missing required argument") || message.contains("has the wrong type")
        || message.contains("is invalid") || message.contains("could not be read")
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
        #expect(
            Set(names) == [
                "open_app", "open_url", "wait", "list_shortcuts", "run_shortcut", "run_applescript",
                "calendar_list_events", "calendar_create_event", "calendar_update_event", "calendar_delete_event",
                "reminders_list", "reminders_create", "clipboard_read", "clipboard_write", "get_frontmost_context",
                "ui_inspect", "ui_click", "ui_type", "ui_press_keys", "screenshot",
                "file_search", "reveal_in_finder", "file_move", "file_trash",
            ]
        )
        for tool in tools {
            #expect(tool.summary.count > 60, "\(tool.name)'s description should say when to use it")
            #expect(tool.definition.name == tool.name)
        }
        #expect(ToolRegistry([]).definitions().isEmpty)
    }

    @Test("the tools that are only a step towards what was asked say whether they open, act or look, and no others do")
    func stepKinds() {
        func names(_ kind: TaskStepKind) -> Set<String> { Set(tools.filter { $0.stepKind == kind }.map(\.name)) }
        #expect(names(.opens) == ["open_app", "open_url"])
        #expect(names(.acts) == ["run_shortcut", "run_applescript", "ui_click", "ui_type", "ui_press_keys"])
        #expect(names(.looks) == ["ui_inspect", "screenshot"])
        // These finish what they were asked to do (or only pass time), so a command needs no second look after them.
        let others = names(.other)
        let finished = [
            "calendar_create_event", "calendar_delete_event", "reminders_create", "clipboard_write", "file_move", "file_trash", "wait",
        ]
        for name in finished {
            #expect(others.contains(name), "\(name)")
        }
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
            } catch let error as ToolInputError where isReadingProblem(error.message) {
                Issue.record("\(tool.name) couldn't read the sample its own schema produced: \(error.message)")
            } catch is ToolInputError {
                // The tool understood the arguments and declined them (there is no such event in this sample), which is fine.
            }
        }
    }

    @Test("the declared risk matches the tool's nature")
    func risks() {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.baselineRisk) })
        #expect(byName["open_app"] == .reversible)
        #expect(byName["open_url"] == .reversible)
        #expect(byName["wait"] == .readOnly)
        #expect(byName["list_shortcuts"] == .readOnly)
        #expect(byName["run_shortcut"] == .sensitive)
        #expect(byName["run_applescript"] == .sensitive)
        #expect(byName["calendar_list_events"] == .readOnly)
        #expect(byName["calendar_create_event"] == .reversible)
        #expect(byName["calendar_update_event"] == .sensitive)
        #expect(byName["calendar_delete_event"] == .sensitive)
        #expect(byName["reminders_list"] == .readOnly)
        #expect(byName["reminders_create"] == .reversible)
        #expect(byName["clipboard_read"] == .reversible)
        #expect(byName["clipboard_write"] == .reversible)
        #expect(byName["get_frontmost_context"] == .readOnly)
        #expect(byName["ui_inspect"] == .readOnly)
        for name in ["ui_click", "ui_type", "ui_press_keys", "screenshot"] {
            #expect(byName[name] == .reversible, "\(name)")
        }
        #expect(byName["file_search"] == .readOnly && byName["reveal_in_finder"] == .readOnly)
        #expect(byName["file_move"] == .sensitive && byName["file_trash"] == .sensitive)
    }

    @Test(
        "every tool that declares itself sensitive is also floored sensitive by the policy, so a wrong tool can't lower its own bar"
    )
    func floorsAgreeWithTools() {
        for tool in tools where tool.baselineRisk == .sensitive {
            #expect(PolicyFloors.floor(for: tool.name) == .sensitive, "\(tool.name)")
        }
        // The ones that can do damage or change what the user sees are pinned by name.
        for name in ["run_shortcut", "run_applescript", "calendar_update_event", "calendar_delete_event"] {
            #expect(PolicyFloors.floor(for: name) == .sensitive, "\(name)")
        }
        for name in ["calendar_create_event", "reminders_create", "clipboard_read", "clipboard_write"] {
            #expect(PolicyFloors.floor(for: name) == .reversible, "\(name)")
        }
    }

    @Test("the tools that read the calendar or reminders declare the permission they need")
    func permissions() {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.requiredPermissions) })
        for name in ["calendar_list_events", "calendar_create_event", "calendar_update_event", "calendar_delete_event"] {
            #expect(byName[name] == [.calendars], "\(name)")
        }
        for name in ["reminders_list", "reminders_create"] {
            #expect(byName[name] == [.reminders], "\(name)")
        }
        #expect(byName["run_applescript"] == [.automation])
    }

    @Test(
        "the tools that drive or read other apps need Accessibility, and the one that looks at the screen needs Screen Recording")
    func uiPermissions() {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.requiredPermissions) })
        for name in ["ui_inspect", "ui_click", "ui_type", "ui_press_keys"] {
            #expect(byName[name] == [.accessibility], "\(name)")
        }
        #expect(byName["screenshot"] == [.screenRecording])
        for name in ["file_search", "reveal_in_finder", "file_move", "file_trash"] {
            #expect(byName[name]?.isEmpty == true, "\(name): macOS asks for folder access itself, when it is needed")
        }
    }

    @Test("what tools return from outside the app is marked untrusted: calendar, reminders, clipboard and window text")
    func outsideContentIsUntrusted() async throws {
        let sample = SystemAccess.sample(
            now: Date(timeIntervalSince1970: 1_790_739_000), timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        let tools = StandardTools.make(
            catalog: FakeAppCatalog.standard,
            opener: FakeOpener(),
            runner: FakeProcessRunner(returning: ProcessOutput(status: 0)),
            system: sample
        )
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in [
            "calendar_list_events", "reminders_list", "clipboard_read", "get_frontmost_context", "ui_inspect", "screenshot",
        ] {
            let result = try await #require(byName[name]).execute([:], context: ToolContext())
            #expect(result.provenance.isUntrusted, "\(name) returned \(result.plainText)")
        }
        let files = try await #require(byName["file_search"]).execute(["query": "invoice"], context: ToolContext())
        #expect(files.provenance.isUntrusted, "file names are outside data")
    }

    @Test(
        "every tool has a friendly title, a one-line description and a category for the Tools tab, so none shows up as a raw name"
    )
    func toolsTabText() {
        for tool in tools {
            let title = L10n.ToolsUI.title(for: tool.name)
            #expect(!title.contains("_") && !title.isEmpty, "\(tool.name) shows as '\(title)'")
            #expect(!L10n.ToolsUI.blurb(for: tool.name, fallback: "").isEmpty, "\(tool.name) has no description of its own")
            #expect(L10n.ToolsUI.category(for: tool.name) != .other, "\(tool.name) has no category")
        }
        #expect(Set(tools.map { L10n.ToolsUI.title(for: $0.name) }).count == tools.count, "titles are all different")
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
