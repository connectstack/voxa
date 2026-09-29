import CoreGraphics
import Foundation

/// What the UI tools ask of the system: read an app's window, click, type, press keys.
///
/// The real thing (`AccessibilityAutomation`) works through the Accessibility API and synthetic input events. Everything
/// it touches sits behind the small protocols below, so the logic, which is where the checks are, runs in tests against a
/// pretend desktop.
public protocol UIAutomating: FrontmostAppProviding {
    /// Lists the front app's window (or menu bar), and remembers the list so its references can be used afterwards.
    func inspect(area: UIArea, maxElements: Int) async throws -> UISnapshot

    /// Says what `target` is, without touching it. Answers at once. Throws if the target can't be found.
    func describe(_ target: UITarget) throws -> UITargetInfo

    func click(_ target: UITarget, button: MouseButton, clickCount: Int) async throws -> UIActionResult
    func type(_ text: String, into target: UITarget) async throws -> UIActionResult
    func press(_ chords: [KeyChord]) async throws -> UIActionResult
}

// MARK: - What the automation is built from

/// A handle to one element of another app's window. It means something only to the tree that issued it.
public struct AXHandle: Hashable, Sendable {
    public let id: Int

    public init(_ id: Int) {
        self.id = id
    }
}

/// What the Accessibility API says about one element.
public struct AXNode: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var help: String?
    public var placeholder: String?
    public var isEnabled: Bool
    public var isFocused: Bool
    public var frame: CGRect?
    public var actions: Set<String>

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        frame: CGRect? = nil,
        actions: Set<String> = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.help = help
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.frame = frame
        self.actions = actions
    }

    /// A password field never gives up what is typed in it.
    public var isSecure: Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// Reads and presses the elements of another app's windows: the Accessibility API, behind a protocol.
public protocol AccessibilityTree: Sendable {
    func focusedWindow(pid: Int32) -> AXHandle?
    func menuBar(pid: Int32) -> AXHandle?
    func focusedElement(pid: Int32) -> AXHandle?
    func node(_ handle: AXHandle) -> AXNode?
    func children(_ handle: AXHandle) -> [AXHandle]
    /// The element at a point on the screen (top-left origin, in points).
    func element(atX x: Double, y: Double, pid: Int32) -> AXHandle?
    /// The default button of the app's front window (the one Return presses), if it has one.
    func defaultButton(pid: Int32) -> AXHandle?
    func press(_ handle: AXHandle) -> Bool
    func showMenu(_ handle: AXHandle) -> Bool
    func focus(_ handle: AXHandle) -> Bool
}

/// Where the windows on the screen are, front to back.
public struct WindowHit: Sendable, Equatable {
    public var pid: Int32
    public var windowID: UInt32
    public var frame: CGRect

    public init(pid: Int32, windowID: UInt32, frame: CGRect) {
        self.pid = pid
        self.windowID = windowID
        self.frame = frame
    }
}

public protocol WindowHitTesting: Sendable {
    /// The frontmost ordinary window that covers `point`.
    func topWindow(at point: CGPoint) -> WindowHit?
    func window(withID id: UInt32) -> WindowHit?
}

/// Synthetic mouse and keyboard input, which lands in whichever app is in front.
public protocol InputSynthesizing: Sendable {
    func click(at point: CGPoint, button: MouseButton, clickCount: Int) async throws
    func type(_ text: String) async throws
    func press(_ chords: [KeyChord]) async throws
}
