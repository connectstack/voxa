import ApplicationServices
import CoreGraphics
import Foundation
import os

/// The real Accessibility API, behind `AccessibilityTree`. It is deliberately thin: it fetches, converts and hands out
/// handles, and every decision about what to do with them is made in `AccessibilityAutomation`, which is tested.
///
/// Handles are numbers standing for elements held here. The elements of the latest listing stay valid until the next one
/// starts (which is when a new window or menu bar is asked for); anything looked up in passing (the focused field, what is
/// under a point) is kept only briefly.
///
/// Every call is a message to another app and can stall if that app is busy, so each has a short timeout.
public final class SystemAccessibilityTree: AccessibilityTree, @unchecked Sendable {
    /// A stuck app must not stall a command: each request gives up after this long.
    public static let messagingTimeout: Float = 1.0
    private static let transientCapacity = 64

    private struct State {
        var next = 1
        var listed: [Int: AXUIElement] = [:]
        var transient: [Int: AXUIElement] = [:]
        var transientOrder: [Int] = []
        /// Elements known to be inside a password field although they don't say so themselves.
        var secure: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    // MARK: Roots

    public func focusedWindow(pid: Int32) -> AXHandle? {
        frontWindow(of: application(pid)).map { startListing(with: $0) }
    }

    /// Every window the app has, front to back. The first is what `focusedWindow` gives when the app isn't active.
    func windows(pid: Int32) -> [AXHandle] {
        let all = elements(application(pid), kAXWindowsAttribute)
        guard let first = all.first else { return [] }
        let head = startListing(with: first)
        return [head] + all.dropFirst().map { adopt($0) }
    }

    /// The window in front in the app: its focused one, else its main one, else the first it has (an app that isn't active
    /// reports neither of the first two).
    private func frontWindow(of app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) ?? elements(app, kAXWindowsAttribute).first
    }

    public func menuBar(pid: Int32) -> AXHandle? {
        element(application(pid), kAXMenuBarAttribute).map { startListing(with: $0) }
    }

    public func focusedElement(pid: Int32) -> AXHandle? {
        guard let focused = element(application(pid), kAXFocusedUIElementAttribute) else { return nil }
        // What has the keyboard in a password field can be the field's editor rather than the field, and the editor doesn't
        // say it is secret; the field around it does. So the field and the two levels above are looked at.
        return rememberBriefly(focused, secure: isInsideSecureField(focused))
    }

    /// Whether the element is a password field, or is inside one (at most two levels down).
    func isInsideSecureField(_ start: AXUIElement) -> Bool {
        var current: AXUIElement? = start
        for _ in 0..<3 {
            guard let element = current else { return false }
            let subrole = Self.string(attribute(element, kAXSubroleAttribute))
            let role = Self.string(attribute(element, kAXRoleAttribute))
            if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return true }
            current = self.element(element, kAXParentAttribute)
        }
        return false
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? (value as Any) : Optional<Any>.none as Any
    }

    public func defaultButton(pid: Int32) -> AXHandle? {
        frontWindow(of: application(pid)).flatMap { defaultButton(in: $0) }
    }

    /// The button the given window presses for Return, when it has one. Split out so a test can ask about its own window when
    /// other windows of the same process are in front of it.
    func defaultButton(inWindow handle: AXHandle) -> AXHandle? {
        lookup(handle).flatMap { defaultButton(in: $0) }
    }

    private func defaultButton(in window: AXUIElement) -> AXHandle? {
        element(window, kAXDefaultButtonAttribute).map { rememberBriefly($0) }
    }

    public func element(atX x: Double, y: Double, pid: Int32) -> AXHandle? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application(pid), Float(x), Float(y), &found) == .success, let found else {
            return nil
        }
        return rememberBriefly(found)
    }

    // MARK: Reading

    public func node(_ handle: AXHandle) -> AXNode? {
        guard let element = lookup(handle) else { return nil }
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
            kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute,
            kAXSizeAttribute,
        ]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            == .success, let list = values as? [Any], list.count == names.count
        else { return nil }
        // An attribute that is missing comes back as an AXValue holding an error, which none of the conversions accept.
        guard let role = Self.string(list[0]) else { return nil }
        var frame: CGRect?
        if let position = Self.point(list[9]), let size = Self.size(list[10]) { frame = CGRect(origin: position, size: size) }
        let isKnownSecure = state.withLockUnchecked { $0.secure.contains(handle.id) }
        return AXNode(
            role: role,
            subrole: isKnownSecure ? "AXSecureTextField" : Self.string(list[1]),
            title: Self.string(list[2]),
            description: Self.string(list[3]),
            value: Self.valueText(list[4]),
            help: Self.string(list[5]),
            placeholder: Self.string(list[6]),
            isEnabled: (list[7] as? Bool) ?? true,
            isFocused: (list[8] as? Bool) ?? false,
            frame: frame,
            actions: actionNames(of: element)
        )
    }

    public func children(_ handle: AXHandle) -> [AXHandle] {
        guard let element = lookup(handle) else { return [] }
        return elements(element, kAXChildrenAttribute).map { adopt($0) }
    }

    // MARK: Acting

    public func press(_ handle: AXHandle) -> Bool {
        guard let element = lookup(handle) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    public func showMenu(_ handle: AXHandle) -> Bool {
        guard let element = lookup(handle) else { return false }
        return AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success
    }

    public func focus(_ handle: AXHandle) -> Bool {
        guard let element = lookup(handle) else { return false }
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: Handles

    private func application(_ pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return app
    }

    /// Begins a new listing: the elements of the last one are let go.
    private func startListing(with root: AXUIElement) -> AXHandle {
        state.withLockUnchecked { state in
            state.listed.removeAll()
            let id = state.next
            state.next += 1
            state.listed[id] = root
            return AXHandle(id)
        }
    }

    /// Adds an element found while walking the current listing.
    private func adopt(_ element: AXUIElement) -> AXHandle {
        state.withLockUnchecked { state in
            let id = state.next
            state.next += 1
            state.listed[id] = element
            return AXHandle(id)
        }
    }

    private func rememberBriefly(_ element: AXUIElement, secure: Bool = false) -> AXHandle {
        state.withLockUnchecked { state in
            let id = state.next
            state.next += 1
            state.transient[id] = element
            if secure { state.secure.insert(id) }
            state.transientOrder.append(id)
            if state.transientOrder.count > Self.transientCapacity {
                let dropped = state.transientOrder.removeFirst()
                state.transient[dropped] = nil
                state.secure.remove(dropped)
            }
            return AXHandle(id)
        }
    }

    private func lookup(_ handle: AXHandle) -> AXUIElement? {
        state.withLockUnchecked { $0.listed[handle.id] ?? $0.transient[handle.id] }
    }

    // MARK: Conversions

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // The type was just checked, so the cast cannot fail.
        return (value as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    private func elements(_ parent: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func actionNames(of element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return Set(list)
    }

    static func string(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    /// The value as text: what is typed in a field, or a number such as a checkbox's 0 or 1.
    static func valueText(_ value: Any) -> String? {
        if let text = string(value) { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    static func point(_ value: Any) -> CGPoint? {
        let ref = value as CFTypeRef
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        // The type was just checked, so the cast cannot fail.
        let axValue = ref as! AXValue  // swiftlint:disable:this force_cast
        var point = CGPoint.zero
        return AXValueGetType(axValue) == .cgPoint && AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: Any) -> CGSize? {
        let ref = value as CFTypeRef
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        // The type was just checked, so the cast cannot fail.
        let axValue = ref as! AXValue  // swiftlint:disable:this force_cast
        var size = CGSize.zero
        return AXValueGetType(axValue) == .cgSize && AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
