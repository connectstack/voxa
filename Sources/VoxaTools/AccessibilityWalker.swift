import CoreGraphics
import Foundation

/// Walks a window (or a menu bar) and picks out what a person could act on: buttons, fields, menu items, rows, and the text
/// around them. Bounded on every side, because a window can hold thousands of elements and an app can be slow to answer.
struct AccessibilityWalker {
    struct Found {
        var handle: AXHandle
        var element: UIElement
    }

    private let tree: any AccessibilityTree
    private let area: UIArea
    private let maxElements: Int
    private let limits: AccessibilityAutomation.Limits
    private let windowFrame: CGRect?
    private let deadline: ContinuousClock.Instant

    private(set) var found: [Found] = []
    private(set) var texts: [String] = []
    private(set) var isTruncated = false
    private var visited = 0

    init(
        tree: any AccessibilityTree,
        area: UIArea,
        maxElements: Int,
        limits: AccessibilityAutomation.Limits,
        windowFrame: CGRect?,
        deadline: ContinuousClock.Instant
    ) {
        self.tree = tree
        self.area = area
        self.maxElements = maxElements
        self.limits = limits
        self.windowFrame = windowFrame
        self.deadline = deadline
    }

    mutating func walk(from root: AXHandle) throws {
        try visit(root, depth: 0, path: [], suppressText: false)
    }

    // MARK: Walking

    private mutating func visit(_ handle: AXHandle, depth: Int, path: [String], suppressText: Bool) throws {
        try Task.checkCancellation()
        guard !isTruncated else { return }
        visited += 1
        if visited > limits.maxNodes || ContinuousClock.now > deadline {
            isTruncated = true
            return
        }
        guard let node = tree.node(handle) else { return }

        switch Self.kind(of: node) {
        case .skip:
            return
        case .container:
            try descend(handle, depth: depth, path: path, suppressText: suppressText)
        case .text:
            if !suppressText { addText(node) }
        case .control(let role):
            if isVisible(node) { list(handle, node, role: role, path: path) }
        case .row:
            guard isVisible(node) else { return }
            list(handle, node, role: "row", path: path, label: Self.label(for: node).nonEmpty ?? derivedText(under: handle))
            try descend(handle, depth: depth, path: path, suppressText: true)
        case .menuBarItem:
            try descend(handle, depth: depth, path: path + [Self.label(for: node)], suppressText: suppressText)
        case .menuItem:
            try visitMenuItem(handle, node, depth: depth, path: path, suppressText: suppressText)
        }
    }

    private mutating func descend(_ handle: AXHandle, depth: Int, path: [String], suppressText: Bool) throws {
        guard depth < limits.maxDepth else {
            isTruncated = true
            return
        }
        for child in tree.children(handle) {
            try visit(child, depth: depth + 1, path: path, suppressText: suppressText)
            if isTruncated { return }
        }
    }

    /// A menu item that opens a submenu is a way to get to more items, not something to press; a plain one is listed with
    /// the menus that lead to it.
    private mutating func visitMenuItem(_ handle: AXHandle, _ node: AXNode, depth: Int, path: [String], suppressText: Bool) throws {
        let label = Self.label(for: node)
        let children = tree.children(handle)
        if children.contains(where: { tree.node($0)?.role == "AXMenu" }) {
            for child in children {
                try visit(child, depth: depth + 1, path: path + [label], suppressText: suppressText)
                if isTruncated { return }
            }
        } else if !label.isEmpty {
            list(handle, node, role: "menu item", path: path + [label], label: label)
        }
    }

    // MARK: Collecting

    private mutating func list(_ handle: AXHandle, _ node: AXNode, role: String, path: [String], label: String? = nil) {
        guard found.count < maxElements else {
            isTruncated = true
            return
        }
        let element = UIElement(
            ref: "",
            role: role,
            label: label ?? Self.label(for: node),
            value: node.isSecure ? nil : Self.displayValue(of: node, role: role),
            isEnabled: node.isEnabled,
            isFocused: node.isFocused,
            isSecure: node.isSecure,
            path: path,
            frame: node.frame
        )
        found.append(Found(handle: handle, element: element))
    }

    private mutating func addText(_ node: AXNode) {
        guard texts.count < limits.maxTexts else { return }
        let text = (node.value ?? node.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isVisible(node), !texts.contains(text) else { return }
        texts.append(text.count > 160 ? String(text.prefix(160)) + "…" : text)
    }

    /// A row in a list or table usually has no label of its own; what it says is the text inside it.
    private func derivedText(under handle: AXHandle) -> String {
        var pieces: [String] = []
        var queue: [(AXHandle, Int)] = [(handle, 0)]
        var index = 0
        while index < queue.count, pieces.count < 3, index < 40 {
            let (current, depth) = queue[index]
            index += 1
            for child in tree.children(current) {
                guard let node = tree.node(child) else { continue }
                if node.role == "AXStaticText" || node.role == "AXTextField" {
                    let text = (node.value ?? node.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { pieces.append(text) }
                } else if depth < 2 {
                    queue.append((child, depth + 1))
                }
                if pieces.count >= 3 { break }
            }
        }
        return pieces.joined(separator: " · ")
    }

    private func isVisible(_ node: AXNode) -> Bool {
        guard area == .window, let frame = node.frame else { return true }
        if frame.width <= 0 || frame.height <= 0 { return false }
        guard let windowFrame else { return true }
        return frame.intersects(windowFrame)
    }

    // MARK: Roles

    enum Kind {
        case control(String)
        case row
        case text
        case menuItem
        case menuBarItem
        case container
        case skip
    }

    static func kind(of node: AXNode) -> Kind {
        switch node.role {
        case "AXButton": return .control("button")
        case "AXCheckBox": return .control(node.subrole == "AXSwitch" ? "switch" : "checkbox")
        case "AXRadioButton": return .control(node.subrole == "AXTabButton" ? "tab" : "radio button")
        case "AXPopUpButton": return .control("pop-up button")
        case "AXMenuButton": return .control("menu button")
        case "AXComboBox": return .control("combo box")
        case "AXTextField":
            return .control(node.subrole == "AXSearchField" ? "search field" : node.isSecure ? "password field" : "text field")
        case "AXSecureTextField": return .control("password field")
        case "AXTextArea": return .control("text area")
        case "AXSlider": return .control("slider")
        case "AXIncrementor": return .control("stepper")
        case "AXLink": return .control("link")
        case "AXDisclosureTriangle": return .control("disclosure triangle")
        case "AXColorWell": return .control("color well")
        case "AXTab": return .control("tab")
        case "AXRow": return .row
        case "AXStaticText": return .text
        case "AXMenuItem": return .menuItem
        case "AXMenuBarItem": return .menuBarItem
        case "AXImage", "AXValueIndicator", "AXScrollBar", "AXBusyIndicator", "AXProgressIndicator", "AXRuler", "AXHandle",
            "AXGrowArea", "AXSplitter":
            return node.actions.contains("AXPress") && !label(for: node).isEmpty ? .control("clickable item") : .skip
        default:
            // Custom controls (in web pages and Electron apps) often show up as plain groups that can still be pressed.
            if node.actions.contains("AXPress"), !label(for: node).isEmpty, node.role != "AXWindow", node.role != "AXApplication" {
                return .control("clickable item")
            }
            return .container
        }
    }

    /// The name a person would give it: its title, else its description, else the hint text.
    static func label(for node: AXNode) -> String {
        for candidate in [node.title, node.description, node.placeholder, node.help] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return ""
    }

    /// The word for any role, for describing what a click landed on: `AXWebArea` becomes "web area".
    static func humanRole(_ role: String) -> String {
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var words = ""
        for character in bare {
            if character.isUppercase, !words.isEmpty { words += " " }
            words.append(character)
        }
        return words.isEmpty ? "element" : words.lowercased()
    }

    /// Switches and checkboxes report 0 and 1; a person would say off and on.
    private static func displayValue(of node: AXNode, role: String) -> String? {
        guard let value = node.value, !value.isEmpty else { return nil }
        switch role {
        case "checkbox", "switch":
            return ["0": "off", "1": "on", "2": "mixed"][value] ?? value
        case "radio button", "tab":
            return ["0": "not selected", "1": "selected"][value] ?? value
        default:
            return value
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
