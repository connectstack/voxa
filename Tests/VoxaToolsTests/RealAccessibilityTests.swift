import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import VoxaCore
import VoxaTestSupport
@testable import VoxaTools

// A process may read and press its own windows through the Accessibility API without being granted anything. That makes it
// possible to run the real `SystemAccessibilityTree`, the real window list and the real automation logic on real controls in a
// window of the test's own. Only the synthetic input is a recorder, so nothing is ever typed or clicked anywhere else, and no
// window belonging to anyone else is read.

private struct FixedApp: FrontmostAppProviding {
    var app: FrontmostApp

    func currentApp() -> FrontmostApp? { app }
}

/// The real Accessibility tree, for elements of the test's own process.
///
/// An app's *own* elements are served by its own main thread, which behaves differently from another app reached over IPC
/// (found by trying it): a menu's elements can't be read from another thread at all, and an action asked for from another
/// thread is performed but reported as failed. So here reads are made on the main queue, and presses and menu opens are made
/// from the calling thread and reported as done, with the tests checking for the effect itself. With another app as the
/// target none of this applies; every read and every action is the real one.
private struct SameProcessTree: AccessibilityTree {
    let tree = SystemAccessibilityTree()

    private func onMain<T: Sendable>(_ read: @Sendable () -> T) -> T {
        Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    /// The fixture's window, not another test's: all the tests share one process, and so its windows.
    func focusedWindow(pid: Int32) -> AXHandle? {
        onMain {
            let windows = tree.windows(pid: pid)
            return windows.first { tree.node($0)?.title == Fixture.title } ?? windows.first
        }
    }
    func menuBar(pid: Int32) -> AXHandle? { onMain { tree.menuBar(pid: pid) } }
    func focusedElement(pid: Int32) -> AXHandle? { onMain { tree.focusedElement(pid: pid) } }
    func node(_ handle: AXHandle) -> AXNode? { onMain { tree.node(handle) } }
    func children(_ handle: AXHandle) -> [AXHandle] { onMain { tree.children(handle) } }
    func element(atX x: Double, y: Double, pid: Int32) -> AXHandle? { onMain { tree.element(atX: x, y: y, pid: pid) } }
    /// The fixture window's default button, read from the real window (not from whichever window of the process is in front,
    /// which can be a HUD panel another suite has up at that moment).
    func defaultButton(pid: Int32) -> AXHandle? {
        onMain {
            let windows = tree.windows(pid: pid)
            guard let window = windows.first(where: { tree.node($0)?.title == Fixture.title }) ?? windows.first else { return nil }
            return tree.defaultButton(inWindow: window)
        }
    }
    func focus(_ handle: AXHandle) -> Bool { tree.focus(handle) }

    func press(_ handle: AXHandle) -> Bool {
        _ = tree.press(handle)
        return true
    }

    func showMenu(_ handle: AXHandle) -> Bool {
        _ = tree.showMenu(handle)
        return true
    }
}

/// A real window with real controls, and what happened to them.
@MainActor
private final class Fixture {
    final class Target: NSObject {
        var presses = 0

        @objc func hit() { presses += 1 }
    }

    nonisolated static let title = "Voxa AX fixture"

    let window: NSWindow
    let target = Target()
    let button: NSButton
    let field: NSTextField
    let secure: NSSecureTextField
    let checkbox: NSButton

    init(defaultButton: String? = nil) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        window = NSWindow(
            contentRect: NSRect(x: 360, y: 360, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = Self.title
        window.level = .modalPanel   // above other apps' windows, and still a level the screenshot code counts as "the window"

        button = NSButton(title: defaultButton ?? "Hello", target: target, action: #selector(Target.hit))
        button.frame = NSRect(x: 20, y: 200, width: 110, height: 30)
        field = NSTextField(frame: NSRect(x: 20, y: 160, width: 220, height: 24))
        field.stringValue = "typed text"
        field.setAccessibilityLabel("Name")
        secure = NSSecureTextField(frame: NSRect(x: 20, y: 120, width: 220, height: 24))
        secure.stringValue = "hunter2"
        secure.setAccessibilityLabel("Password")
        checkbox = NSButton(checkboxWithTitle: "Remember", target: nil, action: nil)
        checkbox.frame = NSRect(x: 20, y: 80, width: 220, height: 24)
        for view in [button, field, secure, checkbox] { window.contentView?.addSubview(view) }
        if defaultButton != nil { window.defaultButtonCell = button.cell as? NSButtonCell }

        // The app's menu bar: the first item is always the application menu, then one with a command that deserves a question.
        let bar = NSMenu()
        bar.addItem(NSMenuItem(title: "App", action: nil, keyEquivalent: ""))
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        // A menu item with nothing to do is greyed out, and the real tree says so; these have something to do.
        for title in ["Save As…", "Move to Trash"] {
            let item = NSMenuItem(title: title, action: #selector(Target.hit), keyEquivalent: "")
            item.target = target
            fileMenu.addItem(item)
            if title == "Save As…" { fileMenu.addItem(.separator()) }
        }
        file.submenu = fileMenu
        bar.addItem(file)
        NSApplication.shared.mainMenu = bar
    }

    func show() async {
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))
    }

    func close() {
        window.close()
        NSApplication.shared.mainMenu = nil
    }

    var app: FrontmostApp { FrontmostApp(name: "Voxa tests", bundleID: "com.example.voxa-tests", pid: getpid()) }
}

/// The real automation over a fixture, with a recorder in place of the keyboard and mouse.
@MainActor
private struct RealRig {
    let fixture: Fixture
    let recorder = SampleDesktop()
    let registry = ScreenshotRegistry()
    let tree = SystemAccessibilityTree()
    let ui: AccessibilityAutomation

    init(_ fixture: Fixture) {
        self.fixture = fixture
        var limits = AccessibilityAutomation.Limits()
        limits.settleDelay = .zero
        ui = AccessibilityAutomation(
            tree: SameProcessTree(),
            input: recorder,
            windows: SystemWindowList(),
            frontmost: FixedApp(app: fixture.app),
            screenshots: registry,
            limits: limits
        )
    }

    func inspect(_ area: UIArea = .window) async throws -> UISnapshot {
        try await ui.inspect(area: area, maxElements: 60)
    }

    func ref(_ label: String, in snapshot: UISnapshot) throws -> String {
        try #require(snapshot.elements.first { $0.label == label || $0.path.last == label }, "no element “\(label)”").ref
    }
}

@Suite(
    "Real Accessibility, on a window of the test's own",
    .serialized,
    .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0)
)
@MainActor
struct RealAccessibilityTests {
    @Test("the window is listed with its real button, fields and checkbox, and a password field never gives up what is in it")
    func listing() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let snapshot = try await RealRig(fixture).inspect()

        #expect(snapshot.windowTitle == Fixture.title)
        let button = try #require(snapshot.elements.first { $0.label == "Hello" })
        #expect(button.role == "button" && button.isEnabled)
        let field = try #require(snapshot.elements.first { $0.label == "Name" })
        #expect(field.role == "text field" && field.value == "typed text")
        let secure = try #require(snapshot.elements.first { $0.isSecure })
        #expect(secure.role == "password field" && secure.value == nil)
        #expect(!snapshot.render().contains("hunter2"))
        let box = try #require(snapshot.elements.first { $0.label == "Remember" })
        #expect(box.role == "checkbox" && box.value == "off")

        // Positions are on the screen, top left first, inside the window's own frame as the window server reports it.
        let bounds = try #require(SystemWindowList().window(withID: UInt32(fixture.window.windowNumber))).frame
        for element in [button, field, secure, box] {
            let frame = try #require(element.frame)
            #expect(bounds.insetBy(dx: -2, dy: -2).contains(frame), "\(element.label) at \(frame) should be inside \(bounds)")
        }
        #expect(snapshot.texts.contains(Fixture.title), "the title bar's own text is listed as text, not as a control")
    }

    @Test("pressing a listed button presses the real button, and a checkbox really flips")
    func pressing() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        var snapshot = try await rig.inspect()

        let result = try await rig.ui.click(.element(ref: try rig.ref("Hello", in: snapshot)), button: .left, clickCount: 1)
        #expect(await waitUntil { fixture.target.presses == 1 })
        #expect(result.message.hasPrefix("Pressed e") && result.message.hasSuffix("(button) in Voxa tests."))

        _ = try await rig.ui.click(.element(ref: try rig.ref("Remember", in: snapshot)), button: .left, clickCount: 1)
        #expect(await waitUntil { fixture.checkbox.state == .on })
        snapshot = try await rig.inspect()
        #expect(snapshot.elements.first { $0.label == "Remember" }?.value == "on")
        #expect(rig.recorder.log.isEmpty, "a press needs no synthetic input at all")
    }

    @Test("typing into a listed field gives that field the real keyboard focus first, and then types")
    func typing() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect()

        let result = try await rig.ui.type("abc", into: .element(ref: try rig.ref("Name", in: snapshot)))
        #expect(await waitUntil { fixture.window.firstResponder is NSTextView }, "the field became the first responder")
        #expect(rig.recorder.log == ["type:abc"])
        #expect(result.message.contains("Typed 3 characters"))
    }

    @Test("a password field is refused for typing, by reference and once it has the focus, on the real thing")
    func passwordFields() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect()
        let secure = try #require(snapshot.elements.first { $0.isSecure })

        await #expect(throws: UIAutomationError.secureField) { try await rig.ui.type("x", into: .element(ref: secure.ref)) }
        #expect(!rig.recorder.log.contains { $0.hasPrefix("type:") })

        // The check that looks at what has the keyboard (a password field, or the editor inside one) is answered from real
        // elements too: the secure field is one, an ordinary field and a button are not.
        let secureFrame = try #require(secure.frame)
        let secureHandle = try #require(rig.tree.element(atX: secureFrame.midX, y: secureFrame.midY, pid: getpid()))
        let fieldFrame = try #require(snapshot.elements.first { $0.label == "Name" }?.frame)
        let fieldHandle = try #require(rig.tree.element(atX: fieldFrame.midX, y: fieldFrame.midY, pid: getpid()))
        #expect(rig.tree.node(secureHandle)?.isSecure == true)
        #expect(rig.tree.node(fieldHandle)?.isSecure == false)
    }

    @Test("a control with no press action is clicked at the middle of where the real window says it is")
    func clickGeometry() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect()
        let field = try #require(snapshot.elements.first { $0.label == "Name" })
        let frame = try #require(field.frame)

        _ = try await rig.ui.click(.element(ref: field.ref), button: .left, clickCount: 1)
        #expect(rig.recorder.log == ["click:\(Int(frame.midX)),\(Int(frame.midY)):left:1"])
        // The window server agrees that the point is in the window (this would be `covered` otherwise).
        let top = try #require(SystemWindowList().topWindow(at: CGPoint(x: frame.midX, y: frame.midY)))
        #expect(top.pid == getpid())
    }

    @Test("what is at a point on the screen is found through the real API, and it is the control drawn there")
    func hitTest() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect()
        let frame = try #require(snapshot.elements.first { $0.label == "Hello" }?.frame)

        let handle = try #require(rig.tree.element(atX: frame.midX, y: frame.midY, pid: getpid()))
        let node = try #require(rig.tree.node(handle))
        #expect(node.role == "AXButton" && node.title == "Hello" && node.actions.contains("AXPress"))
    }

    @Test("the menu bar is listed as commands with their menus, and a command that moves things to the Trash asks")
    func menuBar() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect(.menuBar)
        let paths = snapshot.elements.map { $0.path.joined(separator: " › ") }
        #expect(paths.contains("File › Save As…") && paths.contains("File › Move to Trash"), "\(paths)")
        #expect(!paths.contains { $0.hasSuffix("› ") }, "the separator is not a command")

        let tool = UIClickTool(ui: rig.ui)
        let plain = try tool.assess(["ref": .string(try rig.ref("Save As…", in: snapshot))])
        let trash = try tool.assess(["ref": .string(try rig.ref("Move to Trash", in: snapshot))])
        #expect(plain.risk == .reversible && trash.risk == .sensitive)
    }

    @Test("Return is not pressed blind when the window's real default button says Delete, but is when it says Save")
    func defaultButton() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let dangerous = Fixture(defaultButton: "Delete")
        await dangerous.show()
        let rig = RealRig(dangerous)
        await #expect(throws: UIAutomationError.defaultButtonNeedsAsking) { try await rig.ui.press([try KeyChord.parse("return")]) }
        #expect(rig.recorder.log.isEmpty)
        dangerous.close()

        let harmless = Fixture(defaultButton: "Save")
        await harmless.show()
        defer { harmless.close() }
        let calm = RealRig(harmless)
        _ = try await calm.ui.press([try KeyChord.parse("return")])
        #expect(calm.recorder.log == ["keys:Return"])
    }

    @Test("a control that has been renamed since it was listed is not acted on")
    func renamed() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let ref = try rig.ref("Hello", in: try await rig.inspect())
        fixture.button.title = "Delete everything"
        try await Task.sleep(for: .milliseconds(100))

        await #expect(throws: UIAutomationError.elementChanged) { try await rig.ui.click(.element(ref: ref), button: .left, clickCount: 1) }
        #expect(fixture.target.presses == 0)
    }

    @Test("a tool sees the window, and a click on a listed control goes through the whole path, policy included")
    func throughTheTools() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)

        let listing = try await UIInspectTool(ui: rig.ui).execute([:], context: ToolContext())
        #expect(!listing.isError && listing.provenance == .untrusted(source: "the app's window"))
        #expect(listing.plainText.contains("button “Hello”") && listing.plainText.contains("password field “Password” = (hidden)"))
        #expect(!listing.plainText.contains("hunter2"))

        let snapshot = try await rig.inspect()
        let click = UIClickTool(ui: rig.ui)
        let input: JSONValue = ["ref": .string(try rig.ref("Hello", in: snapshot))]
        let assessment = try click.assess(input)
        #expect(assessment.title == "Click the button “Hello” in Voxa tests")
        _ = try await click.execute(input, context: ToolContext())
        #expect(await waitUntil { fixture.target.presses == 1 })
    }
}

@Suite(
    "A real screenshot, and a click into it",
    .serialized,
    .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0 && CGPreflightScreenCaptureAccess())
)
@MainActor
struct RealScreenshotClickTests {
    @Test("a point in a real screenshot of the window is the same point on the screen, and the control there is found")
    func pointInThePicture() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        let fixture = Fixture()
        await fixture.show()
        defer { fixture.close() }
        let rig = RealRig(fixture)
        let snapshot = try await rig.inspect()
        let frame = try #require(snapshot.elements.first { $0.label == "Hello" }?.frame)

        let request = ScreenCaptureRequest(scope: .window, app: fixture.app, windowID: UInt32(fixture.window.windowNumber))
        let capture = try await SystemScreenCapture().capture(request)
        let record = rig.registry.add(capture, of: fixture.app)
        // Where the button is in the picture: its place in the window, scaled to the picture's pixels.
        let pixel = CGPoint(
            x: (frame.midX - capture.frame.minX) / capture.frame.width * capture.pixelSize.width,
            y: (frame.midY - capture.frame.minY) / capture.frame.height * capture.pixelSize.height
        )
        let target = UITarget.screenshotPoint(id: record.id, x: pixel.x, y: pixel.y)

        let described = try rig.ui.describe(target)
        #expect(described.label == "Hello" && described.role == "button", "the point maps onto the button through the real API")

        _ = try await rig.ui.click(target, button: .left, clickCount: 1)
        let click = try #require(rig.recorder.log.first)
        let parts = click.split(separator: ":")[1].split(separator: ",").compactMap { Int($0) }
        #expect(parts.count == 2 && abs(Double(parts[0]) - frame.midX) <= 1.5 && abs(Double(parts[1]) - frame.midY) <= 1.5, "\(click)")
    }
}
