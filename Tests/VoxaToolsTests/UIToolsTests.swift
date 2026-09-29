import Foundation
import Testing
import VoxaCore
import VoxaPolicy
@testable import VoxaTools

private func decision(_ tool: some AgentTool, _ assessment: ToolAssessment, tainted: Bool = false) -> PolicyDecision {
    var taint = RunTaint()
    if tainted { taint.absorb(.text("x", provenance: .untrusted(source: "the app's window"))) }
    return PolicyEngine().evaluate(toolName: tool.name, baselineRisk: tool.baselineRisk, assessment: assessment, taint: taint)
}

private func isConfirmation(_ decision: PolicyDecision) -> Bool {
    if case .requireConfirmation = decision { true } else { false }
}

@Suite("ui_inspect")
struct UIInspectToolTests {
    @Test("it lists the window as untrusted data, with a notice saying which app was looked at")
    func lists() async throws {
        let rig = AutomationRig()
        let tool = UIInspectTool(ui: rig.ui)
        let result = try await tool.execute([:], context: ToolContext())
        #expect(!result.isError)
        #expect(result.provenance == .untrusted(source: "the app's window"))
        #expect(result.notice == "Looked at Safari")
        #expect(result.plainText.contains("e1 button “Back”"))
        #expect(result.plainText.contains("password field “Password” = (hidden)"))
    }

    @Test("it can read the menu bar instead, and limit how much it lists")
    func menuBarAndLimit() async throws {
        let rig = AutomationRig()
        let tool = UIInspectTool(ui: rig.ui)
        let menu = try await tool.execute(["area": "menu_bar"], context: ToolContext())
        #expect(menu.plainText.contains("Menu bar") && menu.plainText.contains("“File › Close Tab”"))
        let small = try await tool.execute(["max_elements": 10], context: ToolContext())
        #expect(small.plainText.contains("e10 ") && !small.plainText.contains("e11 "))
        #expect(small.plainText.contains("left out"))
    }

    @Test("it only reads, so the policy lets it run, and a paranoid setting asks")
    func policy() throws {
        let rig = AutomationRig()
        let tool = UIInspectTool(ui: rig.ui)
        let assessment = try tool.assess([:])
        #expect(assessment.risk == .readOnly && assessment.title == "Look at Safari" && assessment.block == nil)
        #expect(decision(tool, assessment) == .allow)
        let paranoid = PolicyEngine(configuration: PolicyConfiguration(strictness: .paranoid))
            .evaluate(toolName: tool.name, baselineRisk: tool.baselineRisk, assessment: assessment, taint: RunTaint())
        #expect(isConfirmation(paranoid))
        #expect(tool.requiredPermissions == [.accessibility])
    }

    @Test("an app Voxa keeps out of is refused before anything is read")
    func restricted() throws {
        let rig = AutomationRig()
        rig.desktop.app = FrontmostApp(name: "Bitwarden", bundleID: "com.bitwarden.desktop", pid: SampleDesktop.safariPID)
        let tool = UIInspectTool(ui: rig.ui)
        let assessment = try tool.assess([:])
        #expect(assessment.block?.contains("Voxa doesn't control Bitwarden") == true)
        guard case .deny(let reason) = decision(tool, assessment) else {
            Issue.record("should be denied")
            return
        }
        #expect(reason.contains("passwords"))
    }

    @Test("problems come back as an error result the model can read, not as a crash")
    func errors() async throws {
        let rig = AutomationRig()
        rig.desktop.app = nil
        let result = try await UIInspectTool(ui: rig.ui).execute([:], context: ToolContext())
        #expect(result.isError && result.plainText == "No app is in front." && result.provenance == .trusted)
    }
}

@Suite("ui_click")
struct UIClickToolTests {
    private func rigAndTool() async throws -> (AutomationRig, UIClickTool, UISnapshot) {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        return (rig, UIClickTool(ui: rig.ui), snapshot)
    }

    @Test("an ordinary click runs with a notice, and the card names the app and the control")
    func ordinary() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Reload", in: snapshot)
        let assessment = try tool.assess(["ref": .string(ref)])
        #expect(assessment.risk == .reversible)
        #expect(assessment.title == "Click the button “Reload” in Safari")
        #expect(
            assessment.details == [
                DetailRow("App", "Safari"), DetailRow("Target", "the button “Reload”"), DetailRow("Action", "Click"),
            ])
        #expect(assessment.targetApp == "Safari")
        #expect(decision(tool, assessment) == .allowWithNotice(assessment.title))
    }

    @Test("a control whose label sends, deletes or buys always asks, and says why")
    func consequential() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let assessment = try tool.assess(["ref": .string(try rig.ref("Send Feedback", in: snapshot))])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.reasons.contains { $0.contains("sends or publishes") })
        guard case .requireConfirmation(let prompt) = decision(tool, assessment) else {
            Issue.record("should ask")
            return
        }
        #expect(prompt.risk == .sensitive)
    }

    @Test("a menu command is judged by every step of its path")
    func menuPath() async throws {
        let rig = AutomationRig()
        let trash = rig.desktop.add(
            AXNode(role: "AXMenuItem", title: "Move to Trash", actions: ["AXPress"]),
            to: rig.desktop.children(rig.desktop.children(rig.desktop.menuBarRoot)[0])[0])
        _ = trash
        let snapshot = try await rig.inspect(.menuBar)
        let tool = UIClickTool(ui: rig.ui)
        #expect(try tool.assess(["ref": .string(try rig.ref("Close Tab", in: snapshot))]).risk == .reversible)
        #expect(try tool.assess(["ref": .string(try rig.ref("Move to Trash", in: snapshot))]).risk == .sensitive)
    }

    @Test("after outside content has been read, even an ordinary click asks")
    func afterTaint() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let assessment = try tool.assess(["ref": .string(try rig.ref("Reload", in: snapshot))])
        #expect(isConfirmation(decision(tool, assessment, tainted: true)))
    }

    @Test("a right-click and a double-click are called what they are")
    func actions() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Reload", in: snapshot)
        #expect(try tool.assess(["ref": .string(ref), "button": "right"]).title.hasPrefix("Right-click"))
        #expect(try tool.assess(["ref": .string(ref), "clicks": 2]).title.hasPrefix("Double-click"))
    }

    @Test("a point in a screenshot is described by what is under it, and a spot with nothing there is said to be unknown")
    func screenshotPoint() async throws {
        let (rig, tool, _) = try await rigAndTool()
        let record = try rig.screenshot()
        let hit = try tool.assess(["screenshot": .string(record.id), "x": 55, "y": 133])
        #expect(hit.title == "Click the button “Send Feedback” in Safari")
        #expect(hit.risk == .sensitive)
        for child in rig.desktop.children(rig.desktop.window) { rig.desktop.remove(child) }
        let blank = try tool.assess(["screenshot": .string(record.id), "x": 55, "y": 133])
        #expect(blank.risk == .reversible)
        #expect(blank.reasons.contains { $0.contains("can't tell what is at that spot") })
    }

    @Test("an app that changes the Mac is always asked about, and one that runs commands is refused")
    func restrictions() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Reload", in: snapshot)
        rig.desktop.app = FrontmostApp(
            name: "System Settings", bundleID: "com.apple.systempreferences", pid: SampleDesktop.safariPID)
        let asks = try tool.assess(["ref": .string(ref)])
        #expect(asks.risk == .sensitive && asks.reasons.contains { $0.contains("changes settings of the Mac") })

        rig.desktop.app = FrontmostApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: SampleDesktop.safariPID)
        // The listing was of Safari; with the Terminal in front the reference isn't usable, and neither is the app.
        let blocked = try? tool.assess(["ref": .string(ref)])
        #expect(blocked == nil || blocked?.block != nil)
    }

    @Test("a control that is turned off can't be clicked, and the model is told")
    func disabled() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Back", in: snapshot)
        let toolbar = rig.desktop.children(rig.desktop.window)[0]
        rig.desktop.update(rig.desktop.children(toolbar)[0]) { $0.isEnabled = false }
        // The listing said it was on; asking uses the listing, and doing it looks again.
        _ = try tool.assess(["ref": .string(ref)])
        let result = try await tool.execute(["ref": .string(ref)], context: ToolContext())
        #expect(result.isError && result.plainText.contains("turned off"))
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("the arguments must name exactly one way of saying what to click")
    func arguments() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = JSONValue.string(try rig.ref("Reload", in: snapshot))
        func message(_ input: JSONValue) -> String? {
            do { _ = try tool.assess(input); return nil } catch let error as ToolInputError { return error.message } catch {
                return "\(error)"
            }
        }
        #expect(message([:])?.contains("Say what to click") == true)
        #expect(message(["ref": ref, "screenshot": "s1", "x": 1, "y": 1])?.contains("not both") == true)
        #expect(message(["ref": "reload"])?.contains("isn't a reference") == true)
        #expect(message(["screenshot": "shot", "x": 1, "y": 1])?.contains("isn't the name of a screenshot") == true)
        #expect(message(["screenshot": "s1", "x": 1])?.contains("Say what to click") == true)
        #expect(message(["ref": "e77"])?.contains("no element e77") == true)
    }

    @Test("running it presses the control and says so in Voxa's own words")
    func runs() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Reload", in: snapshot)
        let result = try await tool.execute(["ref": .string(ref)], context: ToolContext())
        #expect(result.plainText == "Pressed \(ref) (button) in Safari." && result.provenance == .trusted)
        #expect(result.notice == "Clicked in Safari")
        #expect(rig.desktop.log == ["press:Reload"])
    }

    @Test("if the world changed, the click isn't made and the result says to look again")
    func stale() async throws {
        let (rig, tool, snapshot) = try await rigAndTool()
        let ref = try rig.ref("Reload", in: snapshot)
        rig.desktop.app = FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 5)
        let result = try await tool.execute(["ref": .string(ref)], context: ToolContext())
        #expect(result.isError && result.plainText.contains("no longer the app in front"))
        #expect(rig.desktop.log.isEmpty)
    }
}

@Suite("ui_type")
struct UITypeToolTests {
    private func focused(_ rig: AutomationRig, description: String) throws {
        let page = rig.desktop.children(rig.desktop.window)[1]
        let field = try #require(rig.desktop.children(page).first { rig.desktop.node($0)?.description == description })
        rig.desktop.setFocused(field)
    }

    @Test("typing into a field asks nothing on its own, and the card shows the text")
    func ordinary() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let tool = UITypeTool(ui: rig.ui)
        let ref = try rig.ref("Search documentation", in: snapshot)
        let assessment = try tool.assess(["text": "actors", "ref": .string(ref)])
        #expect(assessment.risk == .reversible)
        #expect(assessment.title == "Type into Safari")
        #expect(assessment.summary == "Types 6 characters into the text field “Search documentation” in Safari.")
        #expect(assessment.details.contains(DetailRow("Text", "actors", style: .code)))
        #expect(decision(tool, assessment) == .allowWithNotice("Type into Safari"))
        #expect(isConfirmation(decision(tool, assessment, tainted: true)))
    }

    @Test("with no reference it types where the cursor is, and says so")
    func focus() async throws {
        let rig = AutomationRig()
        try focused(rig, description: "Search documentation")
        let assessment = try UITypeTool(ui: rig.ui).assess(["text": "x"])
        #expect(assessment.summary == "Types 1 character into whatever has the keyboard focus in Safari.")
    }

    @Test("a line break in the text can send or submit, so it always asks")
    func lineBreak() throws {
        let rig = AutomationRig()
        try focused(rig, description: "Search documentation")
        let tool = UITypeTool(ui: rig.ui)
        let assessment = try tool.assess(["text": "hello\nworld"])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.reasons.contains { $0.contains("line break") })
        #expect(assessment.details.contains { $0.value == "hello⏎world" }, "the break is shown, not hidden")
        #expect(isConfirmation(decision(tool, assessment)))
    }

    @Test("a password field is refused, by reference and by focus")
    func passwords() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let tool = UITypeTool(ui: rig.ui)
        let secure = try #require(snapshot.elements.first { $0.isSecure })
        let byRef = try tool.assess(["text": "x", "ref": .string(secure.ref)])
        #expect(byRef.block?.contains("password field") == true)
        guard case .deny = decision(tool, byRef) else {
            Issue.record("should be denied")
            return
        }

        try focused(rig, description: "Password")
        #expect(try tool.assess(["text": "x"]).block != nil)
    }

    @Test("hidden characters in the text are shown, so nothing can be tucked into what is typed")
    func hiddenCharacters() throws {
        let rig = AutomationRig()
        try focused(rig, description: "Search documentation")
        let tool = UITypeTool(ui: rig.ui)
        let assessment = try tool.assess(["text": "safe\u{202E}evil\n"])
        guard case .requireConfirmation(let prompt) = decision(tool, assessment) else {
            Issue.record("should ask")
            return
        }
        #expect(prompt.details.contains { $0.value.contains("⟦U+202E⟧") })
    }

    @Test("empty text, and a bad reference, are refused")
    func arguments() throws {
        let tool = UITypeTool(ui: AutomationRig().ui)
        #expect(throws: ToolInputError.self) { try tool.assess(["text": ""]) }
        #expect(throws: ToolInputError.self) { try tool.assess(["text": "x", "ref": "field"]) }
    }

    @Test("running it types, reports how much, and never repeats the text back")
    func runs() async throws {
        let rig = AutomationRig()
        try focused(rig, description: "Search documentation")
        let result = try await UITypeTool(ui: rig.ui).execute(["text": "swift actors"], context: ToolContext())
        #expect(result.plainText == "Typed 12 characters into the focused field in Safari.")
        #expect(result.notice == "Typed in Safari")
        #expect(rig.desktop.value(of: "Search documentation") == "swift actors")
    }

    @Test("an app that runs typed commands is refused")
    func terminal() throws {
        let rig = AutomationRig()
        rig.desktop.app = FrontmostApp(name: "iTerm2", bundleID: "com.googlecode.iterm2", pid: SampleDesktop.safariPID)
        let tool = UITypeTool(ui: rig.ui)
        let assessment = try tool.assess(["text": "ls"])
        #expect(assessment.block?.contains("runs whatever is typed") == true)
    }
}

@Suite("ui_press_keys")
struct UIPressKeysToolTests {
    @Test("an ordinary shortcut runs with a notice")
    func ordinary() throws {
        let tool = UIPressKeysTool(ui: AutomationRig().ui)
        let assessment = try tool.assess(["keys": ["cmd+l", "escape"]])
        #expect(assessment.risk == .reversible)
        #expect(assessment.title == "Press ⌘L, Esc in Safari")
        #expect(assessment.details == [DetailRow("App", "Safari"), DetailRow("Keys", "⌘L, Esc")])
        #expect(decision(tool, assessment) == .allowWithNotice(assessment.title))
    }

    @Test("shortcuts that quit, log out or delete always ask, with what they would do")
    func consequential() throws {
        let tool = UIPressKeysTool(ui: AutomationRig().ui)
        let assessment = try tool.assess(["keys": ["cmd+q"]])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.reasons == ["⌘Q: Quits the app, closing its windows without asking to save."])
        #expect(isConfirmation(decision(tool, assessment)))
    }

    @Test("Return asks in an app where it sends, and not where it doesn't")
    func returnKey() throws {
        let rig = AutomationRig()
        let tool = UIPressKeysTool(ui: rig.ui)
        #expect(try tool.assess(["keys": ["return"]]).risk == .reversible)
        rig.desktop.app = FrontmostApp(name: "Messages", bundleID: "com.apple.MobileSMS", pid: SampleDesktop.safariPID)
        let sends = try tool.assess(["keys": ["return"]])
        #expect(sends.risk == .sensitive && sends.reasons.contains { $0.contains("can send what is typed") })
        #expect(try tool.assess(["keys": ["shift+return"]]).risk == .reversible, "shift-Return is a line break")
    }

    @Test("Mail's send shortcut asks")
    func mailSend() throws {
        let rig = AutomationRig()
        rig.desktop.app = FrontmostApp(name: "Mail", bundleID: "com.apple.mail", pid: SampleDesktop.safariPID)
        let assessment = try UIPressKeysTool(ui: rig.ui).assess(["keys": ["cmd+shift+d"]])
        #expect(assessment.risk == .sensitive && assessment.reasons.contains { $0.contains("sends the email") })
    }

    @Test("a key Voxa doesn't know, an empty list, and too many keys are refused with a message")
    func arguments() throws {
        let tool = UIPressKeysTool(ui: AutomationRig().ui)
        func message(_ input: JSONValue) -> String? {
            do { _ = try tool.assess(input); return nil } catch let error as ToolInputError { return error.message } catch {
                return "\(error)"
            }
        }
        #expect(message(["keys": ["cmd+banana"]])?.contains("'banana'") == true)
        #expect(message(["keys": []])?.contains("no keys") == true)
        #expect(message(["keys": .array(Array(repeating: "a", count: 11))])?.contains("at most 10") == true)
    }

    @Test("an app that runs typed commands is refused, and so is pressing keys with nothing in front")
    func refused() throws {
        let rig = AutomationRig()
        let tool = UIPressKeysTool(ui: rig.ui)
        rig.desktop.app = FrontmostApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: SampleDesktop.safariPID)
        #expect(try tool.assess(["keys": ["return"]]).block != nil)
        rig.desktop.app = nil
        #expect(throws: ToolInputError.self) { try tool.assess(["keys": ["return"]]) }
    }

    @Test("running it presses the keys and says which")
    func runs() async throws {
        let rig = AutomationRig()
        let result = try await UIPressKeysTool(ui: rig.ui).execute(["keys": ["cmd+t"]], context: ToolContext())
        #expect(result.plainText == "Pressed ⌘T in Safari.")
        #expect(rig.desktop.log == ["keys:⌘T"])
    }
}

@Suite("UI tools: what they declare")
struct UIToolDeclarationTests {
    private var tools: [any AgentTool] {
        let ui = AutomationRig().ui
        return [UIInspectTool(ui: ui), UIClickTool(ui: ui), UITypeTool(ui: ui), UIPressKeysTool(ui: ui)]
    }

    @Test("all need Accessibility, and are closed objects")
    func permissions() {
        for tool in tools {
            #expect(tool.requiredPermissions == [.accessibility], "\(tool.name)")
            #expect(tool.inputSchema["additionalProperties"] == false, "\(tool.name)")
            #expect(tool.summary.count > 100, "\(tool.name)")
        }
    }

    @Test("the policy floors the acting tools at reversible, so a wrong declaration can't make them free")
    func floors() {
        #expect(PolicyFloors.floor(for: "ui_click") == .reversible)
        #expect(PolicyFloors.floor(for: "ui_type") == .reversible)
        #expect(PolicyFloors.floor(for: "ui_press_keys") == .reversible)
        for tool in tools where tool.name != "ui_inspect" {
            #expect(tool.baselineRisk == .reversible, "\(tool.name)")
        }
    }
}
