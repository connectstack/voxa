import CoreGraphics
import Foundation
import Testing
@testable import VoxaTools

/// The automation logic, run against a pretend Safari that stands in for the Accessibility API, the window list and the
/// keyboard and mouse. The real system pieces are a thin layer under these seams; what matters, and is tested here, is what
/// is checked before anything is done.
struct AutomationRig {
    let desktop: SampleDesktop
    let shots: ScreenshotRegistry
    let ui: AccessibilityAutomation

    init(hostile: Bool = false, limits: AccessibilityAutomation.Limits? = nil) {
        desktop = .safari(hostile: hostile)
        shots = ScreenshotRegistry()
        var settled = limits ?? AccessibilityAutomation.Limits()
        settled.settleDelay = .zero
        ui = AccessibilityAutomation(
            tree: desktop,
            input: desktop,
            windows: desktop,
            frontmost: desktop,
            screenshots: shots,
            limits: settled
        )
    }

    /// The reference `ui_inspect` gave to the element with this label.
    func ref(_ label: String, in snapshot: UISnapshot) throws -> String {
        try #require(snapshot.elements.first { $0.label == label || $0.path.last == label }, "no element “\(label)”").ref
    }

    func inspect(_ area: UIArea = .window, max: Int = 150) async throws -> UISnapshot {
        try await ui.inspect(area: area, maxElements: max)
    }

    /// A screenshot of the pretend window, as `screenshot` would register it: 500 by 350 pixels for the 1000 by 700 point window.
    @discardableResult
    func screenshot(app: FrontmostApp? = nil) throws -> ScreenshotRecord {
        let capture = ScreenCapture(
            image: Data([0]),
            mediaType: "image/png",
            pixelSize: CGSize(width: 500, height: 350),
            frame: desktop.windowFrame,
            windowID: SampleDesktop.windowID,
            scope: .window
        )
        return shots.add(capture, of: try #require(app ?? desktop.app))
    }
}

@Suite("Accessibility automation: reading")
struct AccessibilityInspectTests {
    @Test("the window is listed with a reference, a role and a name for each control, in reading order")
    func lists() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        #expect(snapshot.app.name == "Safari")
        #expect(snapshot.windowTitle == "Swift Concurrency — Apple Developer")
        #expect(snapshot.elements.map(\.ref).prefix(3) == ["e1", "e2", "e3"])
        let labels = snapshot.elements.map(\.label)
        #expect(labels.starts(with: ["Back", "Forward", "Address and Search", "Reload", "Share"]))
        #expect(labels.contains("Send Feedback") && labels.contains("Documentation") && labels.contains("Remember me"))
        let roles = Dictionary(grouping: snapshot.elements, by: \.role).mapValues(\.count)
        #expect(roles["button"] ?? 0 >= 5)
        #expect(roles["text field"] == 2)
        #expect(roles["checkbox"] == 1 && roles["link"] == 1 && roles["password field"] == 1)
    }

    @Test("text on the page is listed apart from the controls")
    func texts() async throws {
        let snapshot = try await AutomationRig().inspect()
        #expect(snapshot.texts.contains("Actors protect their mutable state."))
        #expect(snapshot.texts.contains("Swift Concurrency"))
    }

    @Test("a control scrolled out of the window is left out")
    func offscreen() async throws {
        let snapshot = try await AutomationRig().inspect()
        #expect(!snapshot.elements.contains { $0.label == "Hidden below the fold" })
    }

    @Test("a control without a name is listed with where it is, so it can still be found")
    func unlabelled() async throws {
        let snapshot = try await AutomationRig().inspect()
        let bare = try #require(snapshot.elements.first { $0.label.isEmpty })
        #expect(bare.frame != nil)
        #expect(snapshot.render().contains("(no label, at"))
    }

    @Test("a password field is listed, but its contents never are")
    func secure() async throws {
        let snapshot = try await AutomationRig().inspect()
        let password = try #require(snapshot.elements.first { $0.isSecure })
        #expect(password.value == nil)
        #expect(!snapshot.render().contains("hunter2"))
        #expect(snapshot.render().contains("= (hidden)"))
    }

    @Test("a checkbox reads on or off, and a focused field says so")
    func states() async throws {
        let rig = AutomationRig()
        rig.desktop.setFocused(nil)
        var snapshot = try await rig.inspect()
        #expect(snapshot.elements.first { $0.label == "Remember me" }?.value == "off")
        let address = try #require(
            rig.desktop.children(rig.desktop.children(rig.desktop.window)[0]).first {
                rig.desktop.node($0)?.description == "Address and Search"
            })
        rig.desktop.setFocused(address)
        snapshot = try await rig.inspect()
        #expect(snapshot.elements.first { $0.label == "Address and Search" }?.isFocused == true)
        #expect(snapshot.render().contains("[focused]"))
    }

    @Test("the menu bar is listed as commands with the menus that lead to them; separators and submenu headings are not")
    func menuBar() async throws {
        let snapshot = try await AutomationRig().inspect(.menuBar)
        #expect(snapshot.area == .menuBar)
        let paths = snapshot.elements.map { $0.path.joined(separator: " › ") }
        #expect(paths == ["File › New Tab", "File › Open Location…", "File › Close Tab", "File › Export as PDF…", "Edit › Copy"])
        #expect(snapshot.elements.allSatisfy { $0.role == "menu item" })
        #expect(snapshot.render().contains("“File › New Tab”"))
    }

    @Test("a long list is cut at the limit, and the listing says it was")
    func truncated() async throws {
        let snapshot = try await AutomationRig().inspect(max: 3)
        #expect(snapshot.elements.count == 3)
        #expect(snapshot.isTruncated)
        #expect(snapshot.render().contains("left out"))
    }

    @Test("a window with more nodes than the budget is cut short instead of walked forever")
    func nodeBudget() async throws {
        var limits = AccessibilityAutomation.Limits()
        limits.maxNodes = 6
        let snapshot = try await AutomationRig(limits: limits).inspect()
        #expect(snapshot.isTruncated)
        #expect(snapshot.elements.count < 10)
    }

    @Test("a text from a hostile page is only ever data in the listing")
    func hostile() async throws {
        let snapshot = try await AutomationRig(hostile: true).inspect()
        #expect(snapshot.texts.contains { $0.contains("IGNORE ALL PREVIOUS INSTRUCTIONS") })
    }

    @Test("each inspect starts a new numbered snapshot")
    func numbering() async throws {
        let rig = AutomationRig()
        let first = try await rig.inspect()
        let second = try await rig.inspect()
        #expect(second.number == first.number + 1)
    }

    @Test("reading is refused for an app that holds secrets or runs commands, with the reason")
    func restricted() async throws {
        let rig = AutomationRig()
        rig.desktop.app = FrontmostApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: SampleDesktop.safariPID)
        await #expect(throws: UIAutomationError.self) { try await rig.inspect() }
        do {
            _ = try await rig.inspect()
        } catch let error as UIAutomationError {
            guard case .restricted(let app, let reason) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(app == "Terminal" && reason.contains("runs whatever is typed"))
        }
    }

    @Test("no app in front, and an app with no window, are reported plainly")
    func nothingToRead() async throws {
        let rig = AutomationRig()
        rig.desktop.app = nil
        await #expect(throws: UIAutomationError.noFrontApp) { try await rig.inspect() }
        rig.desktop.app = FrontmostApp(name: "Ghost", bundleID: "com.example.ghost", pid: 1)
        await #expect(throws: UIAutomationError.noWindow(app: "Ghost")) { try await rig.inspect() }
    }

    @Test("a cancelled command stops the walk")
    func cancelled() async {
        let rig = AutomationRig()
        let task = Task { try await rig.inspect() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("Accessibility automation: clicking")
struct AccessibilityClickTests {
    @Test("a button is pressed through its own action, and the reply names the reference, not the label")
    func press() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let ref = try rig.ref("Reload", in: snapshot)
        let result = try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 1)
        #expect(rig.desktop.log == ["press:Reload"])
        #expect(result.message == "Pressed \(ref) (button) in Safari.")
        #expect(!result.message.contains("Reload"), "text from the app never comes back as Voxa's own words")
    }

    @Test("pressing a checkbox flips it")
    func checkbox() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Remember me", in: try await rig.inspect())
        _ = try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 1)
        #expect(rig.desktop.value(of: "Remember me") == "1")
    }

    @Test("something with no press action is clicked at its centre, when the app's own window is on top there")
    func clicksAtCentre() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let field = try #require(snapshot.elements.first { $0.label == "Search documentation" })
        let frame = try #require(field.frame)
        _ = try await rig.ui.click(.element(ref: field.ref), button: .left, clickCount: 1)
        #expect(rig.desktop.log == ["click:\(Int(frame.midX)),\(Int(frame.midY)):left:1"])
    }

    @Test("a right-click or a double-click is a real click, not a press")
    func otherClicks() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Reload", in: try await rig.inspect())
        _ = try await rig.ui.click(.element(ref: ref), button: .right, clickCount: 1)
        _ = try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 2)
        let log = rig.desktop.log
        #expect(log.count == 2)
        #expect(log[0].hasSuffix(":right:1") && log[1].hasSuffix(":left:2"))
        #expect(!log.contains("press:Reload"))
    }

    @Test("a click that another app's window would take is not made")
    func covered() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let ref = try rig.ref("Search documentation", in: snapshot)
        rig.desktop.coveredBy = 999
        await #expect(throws: UIAutomationError.covered(app: "Safari")) {
            try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 1)
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("if another app has come to the front since the listing, nothing is clicked")
    func appChanged() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Reload", in: try await rig.inspect())
        rig.desktop.app = FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 5)
        await #expect(throws: UIAutomationError.appChanged(expected: "Safari", now: "Notes")) {
            try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 1)
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("an element that has gone, changed its name, or been switched off is not clicked")
    func stale() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let reload = try rig.ref("Reload", in: snapshot)
        let share = try rig.ref("Share", in: snapshot)
        let back = try rig.ref("Back", in: snapshot)

        let toolbar = rig.desktop.children(rig.desktop.window)[0]
        let handles = rig.desktop.children(toolbar)
        rig.desktop.remove(handles[3])  // Reload
        rig.desktop.update(handles[4]) { $0.description = "Bookmark" }  // Share
        rig.desktop.update(handles[0]) { $0.isEnabled = false }  // Back

        await #expect(throws: UIAutomationError.elementGone) {
            try await rig.ui.click(.element(ref: reload), button: .left, clickCount: 1)
        }
        await #expect(throws: UIAutomationError.elementChanged) {
            try await rig.ui.click(.element(ref: share), button: .left, clickCount: 1)
        }
        await #expect(throws: UIAutomationError.disabled) {
            try await rig.ui.click(.element(ref: back), button: .left, clickCount: 1)
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("a reference the listing never had is refused, and a new listing retires the old ones")
    func unknown() async throws {
        let rig = AutomationRig()
        await #expect(throws: UIAutomationError.unknownRef("e1")) {
            try await rig.ui.click(.element(ref: "e1"), button: .left, clickCount: 1)
        }
        _ = try await rig.inspect()
        await #expect(throws: UIAutomationError.unknownRef("e999")) {
            try await rig.ui.click(.element(ref: "e999"), button: .left, clickCount: 1)
        }
        _ = try await rig.inspect(max: 2)
        await #expect(throws: UIAutomationError.unknownRef("e5")) {
            try await rig.ui.click(.element(ref: "e5"), button: .left, clickCount: 1)
        }
    }

    @Test("a click on a spot in a screenshot lands where that spot is on the screen")
    func screenshotPoint() async throws {
        let rig = AutomationRig()
        let record = try rig.screenshot()
        // The middle of a 500 by 350 picture of a 1000 by 700 window at (100, 100).
        _ = try await rig.ui.click(.screenshotPoint(id: record.id, x: 250, y: 175), button: .left, clickCount: 1)
        #expect(rig.desktop.log == ["click:600,450:left:1"])
    }

    @Test("a point outside the picture, an unknown picture, and one of another app are refused")
    func screenshotProblems() async throws {
        let rig = AutomationRig()
        let record = try rig.screenshot()
        await #expect(throws: UIAutomationError.pointOutsideImage) {
            try await rig.ui.click(.screenshotPoint(id: record.id, x: 501, y: 10), button: .left, clickCount: 1)
        }
        await #expect(throws: UIAutomationError.pointOutsideImage) {
            try await rig.ui.click(.screenshotPoint(id: record.id, x: -1, y: 10), button: .left, clickCount: 1)
        }
        await #expect(throws: UIAutomationError.unknownScreenshot("s42")) {
            try await rig.ui.click(.screenshotPoint(id: "s42", x: 1, y: 1), button: .left, clickCount: 1)
        }
        let other = try rig.screenshot(app: FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 5))
        await #expect(throws: UIAutomationError.appChanged(expected: "Notes", now: "Safari")) {
            try await rig.ui.click(.screenshotPoint(id: other.id, x: 1, y: 1), button: .left, clickCount: 1)
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("if the window has moved since the screenshot, the click would land in the wrong place, so it isn't made")
    func windowMoved() async throws {
        let rig = AutomationRig()
        let record = try rig.screenshot()
        rig.desktop.windowFrame = rig.desktop.windowFrame.offsetBy(dx: 40, dy: 0)
        do {
            _ = try await rig.ui.click(.screenshotPoint(id: record.id, x: 250, y: 175), button: .left, clickCount: 1)
            Issue.record("the click should have been refused")
        } catch let error as UIAutomationError {
            guard case .failed(let reason) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(reason.contains("moved or changed size"))
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("what is at a spot must still be what the user was asked about")
    func changedAfterAsking() async throws {
        let rig = AutomationRig()
        _ = try await rig.inspect()
        let record = try rig.screenshot()
        // "Send Feedback" spans x 140 to 280 and y 350 to 380 on the screen; in the half-size picture its middle is (55, 133).
        let target = UITarget.screenshotPoint(id: record.id, x: 55, y: 133)
        let asked = try rig.ui.describe(target)
        #expect(asked.label == "Send Feedback")

        // Between asking and clicking, the page changes what is there.
        let page = rig.desktop.children(rig.desktop.window)[1]
        let button = try #require(rig.desktop.children(page).first { rig.desktop.node($0)?.title == "Send Feedback" })
        rig.desktop.update(button) { $0.title = "Delete Everything" }
        await #expect(throws: UIAutomationError.changedSinceAsked) {
            try await rig.ui.click(target, button: .left, clickCount: 1)
        }
        #expect(rig.desktop.log.isEmpty)
    }

    @Test("clicking needs something to click")
    func noTarget() async throws {
        await #expect(throws: UIAutomationError.self) {
            try await AutomationRig().ui.click(.focused, button: .left, clickCount: 1)
        }
    }
}

@Suite("Accessibility automation: describing")
struct AccessibilityDescribeTests {
    @Test("an element is described from the listing, with its menu path when it has one")
    func element() async throws {
        let rig = AutomationRig()
        let window = try await rig.inspect()
        let info = try rig.ui.describe(.element(ref: try rig.ref("Send Feedback", in: window)))
        #expect(info.label == "Send Feedback" && info.role == "button" && info.isEnabled && !info.isSecure)
        #expect(info.phrase == "the button “Send Feedback”")

        let menu = try await rig.inspect(.menuBar)
        let item = try rig.ui.describe(.element(ref: try rig.ref("Close Tab", in: menu)))
        #expect(item.path == ["File", "Close Tab"])
        #expect(item.phrase == "the menu item “File › Close Tab”")
    }

    @Test("what is at a point in a screenshot is read live, and a spot with nothing is said to be unidentified")
    func point() async throws {
        let rig = AutomationRig()
        let record = try rig.screenshot()
        let hit = try rig.ui.describe(.screenshotPoint(id: record.id, x: 55, y: 133))
        #expect(hit.label == "Send Feedback" && hit.isIdentified)

        // With the page and toolbar gone there is nothing behind the point.
        for child in rig.desktop.children(rig.desktop.window) { rig.desktop.remove(child) }
        let empty = try rig.ui.describe(.screenshotPoint(id: record.id, x: 55, y: 133))
        #expect(!empty.isIdentified)
        #expect(empty.phrase.contains("nothing Voxa can identify"))
    }

    @Test("the focused field is described, and a password field says so")
    func focused() async throws {
        let rig = AutomationRig()
        #expect(try !rig.ui.describe(.focused).isIdentified, "nothing has the focus yet")
        let page = rig.desktop.children(rig.desktop.window)[1]
        let password = try #require(rig.desktop.children(page).first { rig.desktop.node($0)?.isSecure == true })
        rig.desktop.setFocused(password)
        let info = try rig.ui.describe(.focused)
        #expect(info.isSecure && info.role == "password field")
    }

    @Test("a reference from before the app changed is refused")
    func appChanged() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Reload", in: try await rig.inspect())
        rig.desktop.app = FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 5)
        #expect(throws: UIAutomationError.appChanged(expected: "Safari", now: "Notes")) {
            try rig.ui.describe(.element(ref: ref))
        }
    }
}

@Suite("Accessibility automation: typing and keys")
struct AccessibilityTypingTests {
    @Test("text goes into the named field, which is given the focus first")
    func typesIntoRef() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Search documentation", in: try await rig.inspect())
        let result = try await rig.ui.type("actors", into: .element(ref: ref))
        #expect(rig.desktop.log == ["focus:Search documentation", "type:actors"])
        #expect(rig.desktop.value(of: "Search documentation") == "actors")
        #expect(result.message == "Typed 6 characters into \(ref) in Safari.")
        #expect(!result.message.contains("actors"), "the text itself is not repeated back")
    }

    @Test("with no reference, text goes where the cursor already is")
    func typesIntoFocus() async throws {
        let rig = AutomationRig()
        let page = rig.desktop.children(rig.desktop.window)[1]
        let field = try #require(rig.desktop.children(page).first { rig.desktop.node($0)?.description == "Search documentation" })
        rig.desktop.setFocused(field)
        let result = try await rig.ui.type("x", into: .focused)
        #expect(rig.desktop.log == ["type:x"])
        #expect(result.message == "Typed 1 character into the focused field in Safari.")
    }

    @Test("a control that can't take the focus is clicked first, then typed into")
    func clicksToFocus() async throws {
        let rig = AutomationRig()
        let ref = try rig.ref("Documentation", in: try await rig.inspect())  // a link: not a text field
        _ = try await rig.ui.type("hi", into: .element(ref: ref))
        #expect(rig.desktop.log.count == 2)
        #expect(rig.desktop.log[0].hasPrefix("click:") && rig.desktop.log[1] == "type:hi")
    }

    @Test("a password field is never typed into, by reference or by focus")
    func neverPasswords() async throws {
        let rig = AutomationRig()
        let snapshot = try await rig.inspect()
        let secure = try #require(snapshot.elements.first { $0.isSecure })
        await #expect(throws: UIAutomationError.secureField) { try await rig.ui.type("hunter3", into: .element(ref: secure.ref)) }

        let page = rig.desktop.children(rig.desktop.window)[1]
        let handle = try #require(rig.desktop.children(page).first { rig.desktop.node($0)?.isSecure == true })
        rig.desktop.setFocused(handle)
        await #expect(throws: UIAutomationError.secureField) { try await rig.ui.type("hunter3", into: .focused) }
        #expect(!rig.desktop.log.contains { $0.hasPrefix("type:") })
    }

    @Test("a password field is refused by name even when the app doesn't say what has the focus, as one that isn't active doesn't")
    func passwordWithoutFocusReport() async throws {
        let rig = AutomationRig()
        rig.desktop.reportsFocus = false
        let snapshot = try await rig.inspect()
        let secure = try #require(snapshot.elements.first { $0.isSecure })
        await #expect(throws: UIAutomationError.secureField) { try await rig.ui.type("hunter3", into: .element(ref: secure.ref)) }
        #expect(!rig.desktop.log.contains { $0.hasPrefix("type:") })
    }

    @Test("typing into a screenshot point isn't a thing: name a field or use the focus")
    func noPointTyping() async throws {
        let rig = AutomationRig()
        let record = try rig.screenshot()
        await #expect(throws: UIAutomationError.self) {
            try await rig.ui.type("x", into: .screenshotPoint(id: record.id, x: 1, y: 1))
        }
    }

    @Test("keys are pressed in order, and named in the reply")
    func keys() async throws {
        let rig = AutomationRig()
        let chords = try ["cmd+l", "escape"].map(KeyChord.parse)
        let result = try await rig.ui.press(chords)
        #expect(rig.desktop.log == ["keys:⌘L,Esc"])
        #expect(result.message == "Pressed ⌘L, Esc in Safari.")
    }

    @Test("with a password field focused, typing characters is refused, but a shortcut is not")
    func keysInPasswordField() async throws {
        let rig = AutomationRig()
        let page = rig.desktop.children(rig.desktop.window)[1]
        rig.desktop.setFocused(rig.desktop.children(page).first { rig.desktop.node($0)?.isSecure == true })
        await #expect(throws: UIAutomationError.secureField) { try await rig.ui.press([try KeyChord.parse("a")]) }
        _ = try await rig.ui.press([try KeyChord.parse("cmd+a")])
        #expect(rig.desktop.log == ["keys:⌘A"])
    }

    @Test("Return is not pressed blind when the window's default button looks consequential")
    func defaultButton() async throws {
        let rig = AutomationRig()
        let delete = rig.desktop.add(AXNode(role: "AXButton", title: "Delete", actions: ["AXPress"]))
        rig.desktop.setDefaultButton(delete)
        await #expect(throws: UIAutomationError.defaultButtonNeedsAsking) {
            try await rig.ui.press([try KeyChord.parse("return")])
        }
        await #expect(throws: UIAutomationError.defaultButtonNeedsAsking) {
            try await rig.ui.press([try KeyChord.parse("cmd+return")])
        }
        // Shift-Return is a line break, not the default button.
        _ = try await rig.ui.press([try KeyChord.parse("shift+return")])
        #expect(rig.desktop.log == ["keys:⇧Return"])

        rig.desktop.update(delete) { $0.title = "Save" }
        _ = try await rig.ui.press([try KeyChord.parse("return")])
        #expect(rig.desktop.log.last == "keys:Return")
    }

    @Test("keys are not pressed for an app Voxa keeps out of")
    func restricted() async throws {
        let rig = AutomationRig()
        rig.desktop.app = FrontmostApp(name: "1Password", bundleID: "com.1password.1password", pid: SampleDesktop.safariPID)
        await #expect(throws: UIAutomationError.self) { try await rig.ui.press([try KeyChord.parse("cmd+c")]) }
        await #expect(throws: UIAutomationError.self) { try await rig.ui.type("x", into: .focused) }
        #expect(rig.desktop.log.isEmpty)
    }
}
