import CoreGraphics
import Foundation
import os
import VoxaPolicy

/// Drives the front app the way a person would: reads its window through the Accessibility API, presses what is there, and
/// types, using synthetic input.
///
/// Every action is checked against the world at the moment it happens, not only when it was planned. References come from
/// a listing taken earlier, so before acting this looks again: the same app must still be in front, the element must still
/// be there with the same name, and a click that lands on a spot rather than an element must land on the same thing the
/// user was asked about. If anything changed, nothing is done and the model is told to look again.
public final class AccessibilityAutomation: UIAutomating, @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxDepth = 16
        public var maxNodes = 3_000
        public var maxTexts = 40
        /// A stuck app must not stall a command: reading gives up after this long.
        public var timeBudget: Duration = .seconds(3)
        /// A pause after acting, so the window has changed before the next look.
        public var settleDelay: Duration = .milliseconds(150)

        public init() {}
    }

    /// Enough for a busy window, not enough to flood the model.
    public static let maxListed = 400

    private struct Entry {
        var handle: AXHandle
        var element: UIElement
    }

    private struct Listing {
        var app: FrontmostApp
        var entries: [String: Entry]
    }

    private struct State {
        var counter = 0
        var listing: Listing?
        /// What each target looked like when the user was asked about it.
        var described: [UITarget: UITargetInfo] = [:]
    }

    private let tree: any AccessibilityTree
    private let input: any InputSynthesizing
    private let windows: any WindowHitTesting
    private let frontmost: any FrontmostAppProviding
    private let screenshots: ScreenshotRegistry
    private let limits: Limits
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        tree: any AccessibilityTree,
        input: any InputSynthesizing,
        windows: any WindowHitTesting,
        frontmost: any FrontmostAppProviding,
        screenshots: ScreenshotRegistry,
        limits: Limits = Limits()
    ) {
        self.tree = tree
        self.input = input
        self.windows = windows
        self.frontmost = frontmost
        self.screenshots = screenshots
        self.limits = limits
    }

    public func currentApp() -> FrontmostApp? {
        frontmost.currentApp()
    }

    /// The app in front, unless it is one Voxa keeps out of.
    private func frontApp() throws -> FrontmostApp {
        guard let app = frontmost.currentApp() else { throw UIAutomationError.noFrontApp }
        if case .untouchable(let reason) = AppSafety.restriction(bundleID: app.bundleID) {
            throw UIAutomationError.restricted(app: app.name, reason: reason)
        }
        return app
    }

    // MARK: Reading

    public func inspect(area: UIArea, maxElements: Int) async throws -> UISnapshot {
        let app = try frontApp()
        let root: AXHandle? = area == .window ? tree.focusedWindow(pid: app.pid) : tree.menuBar(pid: app.pid)
        guard let root else { throw UIAutomationError.noWindow(app: app.name) }
        let rootNode = tree.node(root)

        var walker = AccessibilityWalker(
            tree: tree,
            area: area,
            maxElements: min(max(maxElements, 1), Self.maxListed),
            limits: limits,
            windowFrame: area == .window ? rootNode?.frame : nil,
            deadline: ContinuousClock.now.advanced(by: limits.timeBudget)
        )
        try walker.walk(from: root)

        var elements: [UIElement] = []
        var entries: [String: Entry] = [:]
        for (index, item) in walker.found.enumerated() {
            var element = item.element
            element.ref = "e\(index + 1)"
            elements.append(element)
            entries[element.ref] = Entry(handle: item.handle, element: element)
        }
        let listed = entries
        let number = state.withLock { state -> Int in
            state.counter += 1
            state.listing = Listing(app: app, entries: listed)
            state.described = [:]
            return state.counter
        }
        return UISnapshot(
            app: app,
            area: area,
            windowTitle: area == .window ? rootNode?.title : nil,
            elements: elements,
            texts: walker.texts,
            isTruncated: walker.isTruncated,
            number: number
        )
    }

    // MARK: Describing

    public func describe(_ target: UITarget) throws -> UITargetInfo {
        let info: UITargetInfo
        switch target {
        case .element(let ref): info = try describeElement(ref)
        case .focused: info = try describeFocused()
        case .screenshotPoint(let id, let x, let y): info = try describePoint(id: id, x: x, y: y)
        }
        state.withLock { $0.described[target] = info }
        return info
    }

    private func describeElement(_ ref: String) throws -> UITargetInfo {
        guard let listing = state.withLock({ $0.listing }), let entry = listing.entries[ref] else {
            throw UIAutomationError.unknownRef(ref)
        }
        let app = try frontApp()
        guard app.pid == listing.app.pid else { throw UIAutomationError.appChanged(expected: listing.app.name, now: app.name) }
        let element = entry.element
        return UITargetInfo(
            app: app,
            role: element.role,
            label: element.label.isEmpty ? nil : element.label,
            path: element.path,
            isEnabled: element.isEnabled,
            isSecure: element.isSecure
        )
    }

    private func describeFocused() throws -> UITargetInfo {
        let app = try frontApp()
        guard let handle = tree.focusedElement(pid: app.pid), let node = tree.node(handle) else {
            return UITargetInfo(app: app, role: "control", isIdentified: false)
        }
        return info(for: node, app: app)
    }

    private func describePoint(id: String, x: Double, y: Double) throws -> UITargetInfo {
        let app = try frontApp()
        guard let record = screenshots.record(id) else { throw UIAutomationError.unknownScreenshot(id) }
        guard record.app.pid == app.pid else { throw UIAutomationError.appChanged(expected: record.app.name, now: app.name) }
        guard let point = record.screenPoint(x: x, y: y) else { throw UIAutomationError.pointOutsideImage }
        return infoAt(point, app: app)
    }

    private func infoAt(_ point: CGPoint, app: FrontmostApp) -> UITargetInfo {
        guard let handle = tree.element(atX: point.x, y: point.y, pid: app.pid), let node = tree.node(handle) else {
            return UITargetInfo(app: app, role: "spot", isIdentified: false)
        }
        return info(for: node, app: app)
    }

    private func info(for node: AXNode, app: FrontmostApp) -> UITargetInfo {
        let label = AccessibilityWalker.label(for: node)
        let role: String
        if case .control(let name) = AccessibilityWalker.kind(of: node) {
            role = name
        } else {
            role = AccessibilityWalker.humanRole(node.role)
        }
        return UITargetInfo(
            app: app,
            role: role,
            label: label.isEmpty ? nil : label,
            isEnabled: node.isEnabled,
            isSecure: node.isSecure
        )
    }

    // MARK: Clicking

    public func click(_ target: UITarget, button: MouseButton, clickCount: Int) async throws -> UIActionResult {
        let app = try frontApp()
        switch target {
        case .element(let ref):
            return try await clickElement(ref, app: app, button: button, count: clickCount)
        case .screenshotPoint(let id, let x, let y):
            return try await clickScreenshot(id: id, at: CGPoint(x: x, y: y), app: app, button: button, count: clickCount)
        case .focused:
            throw UIAutomationError.failed("Name what to click: an element from ui_inspect, or a point in a screenshot.")
        }
    }

    private func clickElement(_ ref: String, app: FrontmostApp, button: MouseButton, count: Int) async throws -> UIActionResult {
        let entry = try entry(for: ref, app: app)
        let node = try verified(entry)
        guard node.isEnabled else { throw UIAutomationError.disabled }
        let what = "\(ref) (\(entry.element.role))"

        if button == .left, count == 1, node.actions.contains("AXPress"), tree.press(entry.handle) {
            await settle()
            return UIActionResult("Pressed \(what) in \(app.name).")
        }
        if button == .right, node.actions.contains("AXShowMenu"), tree.showMenu(entry.handle) {
            await settle()
            return UIActionResult("Opened the context menu of \(what) in \(app.name).")
        }
        // No direct action for this: a real click at its centre does the same as a person's.
        guard let frame = node.frame, !frame.isEmpty else {
            throw UIAutomationError.failed("\(ref) can't be pressed directly and has no position on the screen to click.")
        }
        try await post(CGPoint(x: frame.midX, y: frame.midY), app: app, button: button, count: count)
        return UIActionResult("Clicked \(what) in \(app.name).")
    }

    /// - Parameter pixel: The point in the picture, in the picture's own pixels.
    private func clickScreenshot(
        id: String,
        at pixel: CGPoint,
        app: FrontmostApp,
        button: MouseButton,
        count: Int
    ) async throws -> UIActionResult {
        guard let record = screenshots.record(id) else { throw UIAutomationError.unknownScreenshot(id) }
        guard record.app.pid == app.pid else { throw UIAutomationError.appChanged(expected: record.app.name, now: app.name) }
        guard let point = record.screenPoint(x: pixel.x, y: pixel.y) else { throw UIAutomationError.pointOutsideImage }

        // A window that has moved or been resized would send the click somewhere the picture doesn't show.
        if record.scope == .window, let windowID = record.windowID {
            guard let now = windows.window(withID: windowID), now.pid == app.pid, now.frame.isClose(to: record.frame) else {
                throw UIAutomationError.failed(
                    "The window moved or changed size since screenshot \(id) was taken, so the click would land in the wrong place. Nothing was done. Take a new screenshot."
                )
            }
        }
        // What is at that spot now must be what the user was asked about.
        let target = UITarget.screenshotPoint(id: id, x: pixel.x, y: pixel.y)
        if let asked = state.withLock({ $0.described[target] }), !infoAt(point, app: app).describesSameThing(as: asked) {
            throw UIAutomationError.changedSinceAsked
        }
        try await post(point, app: app, button: button, count: count)
        return UIActionResult("Clicked at (\(Int(pixel.x)), \(Int(pixel.y))) in screenshot \(id), in \(app.name).")
    }

    /// The click itself, once every check has passed: the window under the point must belong to the app being driven.
    private func post(_ point: CGPoint, app: FrontmostApp, button: MouseButton, count: Int) async throws {
        guard let top = windows.topWindow(at: point), top.pid == app.pid else { throw UIAutomationError.covered(app: app.name) }
        try await input.click(at: point, button: button, clickCount: count)
        await settle()
    }

    // MARK: Typing

    public func type(_ text: String, into target: UITarget) async throws -> UIActionResult {
        let app = try frontApp()
        var place = "the focused field"
        switch target {
        case .focused:
            break
        case .element(let ref):
            let entry = try entry(for: ref, app: app)
            let node = try verified(entry)
            guard node.isEnabled else { throw UIAutomationError.disabled }
            if node.isSecure { throw UIAutomationError.secureField }
            if !tree.focus(entry.handle) {
                // Some fields only take the keyboard from a click.
                guard let frame = node.frame, !frame.isEmpty else {
                    throw UIAutomationError.failed("\(ref) can't be given the keyboard focus.")
                }
                try await post(CGPoint(x: frame.midX, y: frame.midY), app: app, button: .left, count: 1)
            }
            place = ref
        case .screenshotPoint:
            throw UIAutomationError.failed("Type into an element by its reference, or into whatever has the focus.")
        }
        // Whatever has the keyboard now must not be a password field.
        if let handle = tree.focusedElement(pid: app.pid), tree.node(handle)?.isSecure == true {
            throw UIAutomationError.secureField
        }
        try await input.type(text)
        await settle()
        return UIActionResult("Typed \(text.count) character\(text.count == 1 ? "" : "s") into \(place) in \(app.name).")
    }

    // MARK: Keys

    public func press(_ chords: [KeyChord]) async throws -> UIActionResult {
        let app = try frontApp()
        let secureFocus = tree.focusedElement(pid: app.pid).flatMap { tree.node($0) }?.isSecure == true
        if secureFocus, chords.contains(where: \.isTypedCharacter) { throw UIAutomationError.secureField }
        if chords.contains(where: { $0.isReturn && $0.modifiers.isSubset(of: [.command]) }) {
            try guardDefaultButton(of: app)
        }
        try await input.press(chords)
        await settle()
        let keys = chords.map(\.displayString).joined(separator: ", ")
        return UIActionResult("Pressed \(keys) in \(app.name).")
    }

    /// Return presses the window's default button. If that button looks consequential ("Delete", "Send"), Voxa won't press it
    /// blind: the model has to click it, which asks the user.
    private func guardDefaultButton(of app: FrontmostApp) throws {
        guard let handle = tree.defaultButton(pid: app.pid), let node = tree.node(handle) else { return }
        if UILabelRisk.concern(in: AccessibilityWalker.label(for: node)) != nil {
            throw UIAutomationError.defaultButtonNeedsAsking
        }
    }

    // MARK: Helpers

    private func entry(for ref: String, app: FrontmostApp) throws -> Entry {
        guard let listing = state.withLock({ $0.listing }), let entry = listing.entries[ref] else {
            throw UIAutomationError.unknownRef(ref)
        }
        guard listing.app.pid == app.pid else { throw UIAutomationError.appChanged(expected: listing.app.name, now: app.name) }
        return entry
    }

    /// The element as it is now, or the reason it can't be acted on: gone, or not what was listed.
    private func verified(_ entry: Entry) throws -> AXNode {
        guard let node = tree.node(entry.handle) else { throw UIAutomationError.elementGone }
        // A row is named after its contents, which change as a list scrolls, and a menu item is only ever looked at once it
        // has been listed, so only named controls are compared.
        if entry.element.role != "row", entry.element.role != "menu item", !entry.element.label.isEmpty {
            let label = AccessibilityWalker.label(for: node)
            if !label.isEmpty, label != entry.element.label { throw UIAutomationError.elementChanged }
        }
        return node
    }

    private func settle() async {
        try? await Task.sleep(for: limits.settleDelay)
    }
}

extension UITargetInfo {
    /// Whether two looks at a spot found the same thing.
    fileprivate func describesSameThing(as other: UITargetInfo) -> Bool {
        isIdentified == other.isIdentified && role == other.role && label == other.label && path == other.path
    }
}

extension CGRect {
    /// Within a couple of points on every side: the same window, allowing for rounding.
    fileprivate func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
