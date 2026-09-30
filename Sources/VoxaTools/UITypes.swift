import CoreGraphics
import Foundation

/// The app the user is working in. Voxa's own windows never count.
public struct FrontmostApp: Sendable, Equatable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32

    public init(name: String, bundleID: String? = nil, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

public protocol FrontmostAppProviding: Sendable {
    /// The app in front right now, or nil when there is none (or Voxa hasn't started following yet). Answers at once, from
    /// what was seen the last time the front app changed, so a tool can describe a call without waiting.
    func currentApp() -> FrontmostApp?
}

/// Which part of the front app `ui_inspect` reads.
public enum UIArea: String, Sendable, CaseIterable {
    case window
    case menuBar = "menu_bar"
}

public enum MouseButton: String, Sendable, CaseIterable {
    case left
    case right
}

/// One thing in an app's window that can be pressed, typed into or read, as `ui_inspect` lists it.
public struct UIElement: Sendable, Equatable {
    /// A short name valid until the next `ui_inspect`: `e1`, `e2`...
    public var ref: String
    /// In plain words: "button", "text field", "menu item".
    public var role: String
    public var label: String
    public var value: String?
    public var isEnabled: Bool
    public var isFocused: Bool
    public var isSecure: Bool
    /// For menu items, the menus leading to it, ending with its own name: `File`, `Save As…`.
    public var path: [String]
    /// Where it is on the screen, in points.
    public var frame: CGRect?

    public init(
        ref: String,
        role: String,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isSecure: Bool = false,
        path: [String] = [],
        frame: CGRect? = nil
    ) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSecure = isSecure
        self.path = path
        self.frame = frame
    }
}

/// What `ui_inspect` found.
public struct UISnapshot: Sendable, Equatable {
    public var app: FrontmostApp
    public var area: UIArea
    public var windowTitle: String?
    public var elements: [UIElement]
    /// Text shown in the window that isn't a control (headings, messages).
    public var texts: [String]
    /// Whether some of what is there was left out, to keep the list short.
    public var isTruncated: Bool
    /// Which snapshot this is; references from older ones no longer work.
    public var number: Int

    public init(
        app: FrontmostApp,
        area: UIArea,
        windowTitle: String? = nil,
        elements: [UIElement],
        texts: [String] = [],
        isTruncated: Bool = false,
        number: Int = 1
    ) {
        self.app = app
        self.area = area
        self.windowTitle = windowTitle
        self.elements = elements
        self.texts = texts
        self.isTruncated = isTruncated
        self.number = number
    }
}

/// The web browsers Voxa knows by name. A browser draws the page itself, and most of them show a window's Accessibility tree
/// little or nothing of it until their own accessibility is switched on, so a listing of one is mostly its toolbar.
enum Browsers {
    private static let bundleIDs: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.beta",
        "com.google.chrome.dev", "com.google.chrome.canary", "com.brave.browser", "com.brave.browser.beta",
        "com.brave.browser.nightly", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.microsoft.edgemac",
        "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium",
        "com.duckduckgo.macos.browser", "app.zen-browser.zen",
    ]

    static func isBrowser(bundleID: String?) -> Bool {
        bundleID.map { bundleIDs.contains($0.lowercased()) } ?? false
    }
}

extension UISnapshot {
    static let maxValueCharacters = 200

    /// The list as the model reads it: one element per line, with the reference to use on it.
    public func render() -> String {
        var lines = ["App: \(app.name)" + (app.bundleID.map { " (\($0))" } ?? "")]
        switch area {
        case .window: lines.append("Window: " + (windowTitle.map { "“\($0)”" } ?? "(untitled)"))
        case .menuBar: lines.append("Menu bar")
        }
        if elements.isEmpty {
            lines.append("Nothing that can be clicked or typed into was found. Try a screenshot, or a keyboard shortcut.")
        } else {
            lines.append("Elements (use the ref with ui_click or ui_type; refs only work until the next ui_inspect):")
            lines += elements.map(Self.line)
            // A page with anything on it has links. A browser listing without one is a listing of the toolbar only.
            if area == .window, Browsers.isBrowser(bundleID: app.bundleID), !elements.contains(where: { $0.role == "link" }) {
                lines.append(
                    "This is a web browser and the page itself isn't listed: browsers show little of a page here. "
                        + "To see or click something on the page, take a screenshot."
                )
            }
        }
        if !texts.isEmpty {
            lines.append("Text shown:")
            lines += texts.map { "- \($0)" }
        }
        if isTruncated {
            lines.append("[Some elements were left out to keep this short. Look at a smaller area, or take a screenshot.]")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ element: UIElement) -> String {
        var text = "\(element.ref) \(element.role)"
        if element.path.count > 1 {
            text += " “\(element.path.joined(separator: " › "))”"
        } else if !element.label.isEmpty {
            text += " “\(element.label)”"
        } else if let frame = element.frame {
            text += " (no label, at \(Int(frame.midX)),\(Int(frame.midY)))"
        } else {
            text += " (no label)"
        }
        if element.isSecure {
            text += " = (hidden)"
        } else if let value = element.value, !value.isEmpty {
            let single = value.replacingOccurrences(of: "\n", with: "⏎")
            text += " = “" + (single.count > maxValueCharacters ? String(single.prefix(maxValueCharacters)) + "…" : single) + "”"
        }
        if element.isFocused { text += " [focused]" }
        if !element.isEnabled { text += " [disabled]" }
        return text
    }
}

/// What a call would act on: an element from `ui_inspect`, a point in a screenshot, or whatever has the keyboard focus.
public enum UITarget: Sendable, Equatable, Hashable {
    case element(ref: String)
    case screenshotPoint(id: String, x: Double, y: Double)
    case focused
}

/// What Voxa knows about a target, for the confirmation card and for the checks before acting.
public struct UITargetInfo: Sendable, Equatable {
    public var app: FrontmostApp
    public var role: String
    public var label: String?
    public var path: [String]
    public var isEnabled: Bool
    public var isSecure: Bool
    /// Whether anything is known about what is there; false for a point on a picture with nothing behind it.
    public var isIdentified: Bool

    public init(
        app: FrontmostApp,
        role: String,
        label: String? = nil,
        path: [String] = [],
        isEnabled: Bool = true,
        isSecure: Bool = false,
        isIdentified: Bool = true
    ) {
        self.app = app
        self.role = role
        self.label = label
        self.path = path
        self.isEnabled = isEnabled
        self.isSecure = isSecure
        self.isIdentified = isIdentified
    }

    /// "the “Save” button", "the text field “Search”", "an unlabelled area".
    public var phrase: String {
        guard isIdentified else { return "a spot with nothing Voxa can identify" }
        if path.count > 1 { return "the menu item “\(path.joined(separator: " › "))”" }
        if let label, !label.isEmpty { return "the \(role) “\(label)”" }
        return "an unlabelled \(role)"
    }
}

/// What an action did, in Voxa's own words (never the app's).
public struct UIActionResult: Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Why a UI action was not carried out. The messages are for the model, which relays them.
public enum UIAutomationError: Error, Sendable, Equatable {
    case noFrontApp
    case noWindow(app: String)
    case restricted(app: String, reason: String)
    case unknownRef(String)
    case unknownScreenshot(String)
    case appChanged(expected: String, now: String?)
    case elementGone
    case elementChanged
    case disabled
    case secureField
    case covered(app: String)
    case pointOutsideImage
    case changedSinceAsked
    case defaultButtonNeedsAsking
    case failed(String)

    public var message: String {
        switch self {
        case .noFrontApp:
            "No app is in front."
        case .noWindow(let app):
            "\(app) has no window Voxa can read. It may be minimized, or the app may not support Accessibility."
        case .restricted(let app, let reason):
            "Voxa doesn't read or control \(app). \(reason)"
        case .unknownRef(let ref):
            "There is no element \(ref). References only work until the next ui_inspect: call it again."
        case .unknownScreenshot(let id):
            "There is no screenshot \(id) any more. Take a new one with screenshot."
        case .appChanged(let expected, let now):
            "\(expected) is no longer the app in front" + (now.map { " (\($0) is)" } ?? "") + ". Nothing was done. Look again first."
        case .elementGone:
            "That element is gone from the window. Nothing was done. Call ui_inspect again."
        case .elementChanged:
            "That element changed since it was listed. Nothing was done. Call ui_inspect again."
        case .disabled:
            "That control is turned off, so it can't be used right now."
        case .secureField:
            "That is a password field. Voxa never types into one; ask the user to type it themselves."
        case .covered(let app):
            "Another window is on top of that spot, so the click would not reach \(app). Nothing was done."
        case .pointOutsideImage:
            "That point is outside the screenshot. Use x and y within the picture's size."
        case .changedSinceAsked:
            "What is at that spot changed after the user was asked, so nothing was done. Look again first."
        case .defaultButtonNeedsAsking:
            "Return would press the window's default button, which looks consequential, so the user has to approve it. "
                + "Click that button with ui_click instead, so they are asked."
        case .failed(let reason):
            reason
        }
    }
}
