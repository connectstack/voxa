import AppKit
import SwiftUI
import VoxaCore

/// How the bar asks for the keyboard and gives it up: by making Voxa the active app, and by yielding that again. The real one uses the
/// application; tests use a fake, because activation belongs to every window in the process, not to the one under test.
@MainActor
public protocol KeyboardActivating: AnyObject {
    var isActive: Bool { get }
    func activate()
    func deactivate()
}

/// The real thing.
@MainActor
final class ApplicationActivation: KeyboardActivating {
    var isActive: Bool { NSApp.isActive }
    func activate() { NSApp.activate() }
    func deactivate() { NSApp.deactivate() }
}

/// The Voxa bar's window: a borderless panel at the top of the screen.
///
/// Keystrokes go to the key window of the active app, and Voxa's commands press keys and type in whatever is in front ("type hello",
/// "press ⌘S"): if the bar still had the keyboard while a command ran, those keys would land in its field. So the bar can have the
/// keyboard only while it is open and nothing is under way (`allowsKey`), and gives it back to the app that had it as soon as a
/// command starts (`CommandBarController.releaseKeyboard`) or the bar goes. A question is never answered by a keystroke it took.
final class CommandBarPanel: NSPanel {
    weak var model: CommandBarModel?
    /// Called when the panel really has the keyboard. Typing goes to the active app, so the bar makes Voxa the active app for as long
    /// as it is being typed into. (The panel is non-activating so that merely showing it doesn't; this asks for it once it does have
    /// the keyboard.)
    var onBecomeKey: (() -> Void)?
    /// Whether the panel may take the keyboard.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onBecomeKey?()
    }

    /// A menu-bar app has no Edit menu, so ⌘A, ⌘C, ⌘X, ⌘V and ⌘Z would do nothing in the field. They are sent on by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]) else {
            return super.performKeyEquivalent(with: event)
        }
        let shifted = flags.contains(.shift)
        let action: Selector? =
            switch (event.charactersIgnoringModifiers?.lowercased(), shifted) {
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("x", false): #selector(NSText.cut(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc, when the field doesn't have the focus.
    override func cancelOperation(_ sender: Any?) {
        model?.escape()
    }
}

/// Owns the Voxa bar's window: the one place Voxa shows itself. It holds a field to type in and a microphone (`CommandBarModel`), and
/// everything a command goes through below them (`HUDModel`): what was heard, progress, the reply, a problem, and the question that
/// needs an answer. It is what the session and the confirmations present to (`HUDPresenting`).
///
/// It is at the top centre of the screen, just below the menu bar, and there are two reasons it is showing. The person opened it (the
/// shortcut, the menu): it is theirs to type in and click, until they put it away. Or a command is under way (the push-to-talk key,
/// Siri, something typed or said): it shows what the command is doing, without taking the keyboard or the clicks, and goes when
/// that is over. The two can overlap: a bar that is listening stays where it can be seen, so the microphone is always visibly live,
/// and goes back to waiting for the next command when a command is over.
@MainActor
public final class CommandBarController: HUDPresenting {
    public let model: CommandBarModel
    private let content: HUDModel
    private let clock: any Clock<Duration>
    private let activation: any KeyboardActivating

    private var panel: CommandBarPanel?
    /// The screen the bar appeared on. Fixed while it stays on screen, so that it doesn't hop between displays as the pointer moves.
    private var anchorScreen: NSScreen?
    private var resignObserver: (any NSObjectProtocol)?
    private var hideTask: Task<Void, Never>?
    /// Bumped on every show and hide, so that a stale fade-out or delayed hide can tell it has been superseded.
    private var visibilityGeneration = 0
    /// Whether a command has the bar showing, from its start until what it had to say is over.
    private var sessionActive = false

    /// Whether the bar should stay when the person clicks elsewhere (the microphone is on).
    public var keepsOpen: @MainActor () -> Bool = { false }

    /// - Parameter activation: How the bar takes the keyboard; the application's own, unless a test brings its own.
    public init(
        model: CommandBarModel = CommandBarModel(),
        content: HUDModel = HUDModel(levelInterval: 0.066),
        clock: any Clock<Duration> = ContinuousClock(),
        activation: (any KeyboardActivating)? = nil
    ) {
        self.model = model
        self.content = content
        self.clock = clock
        self.activation = activation ?? ApplicationActivation()
        model.isOpen = false
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// Whether the bar has the keyboard right now.
    public var hasKeyboard: Bool { panel?.isKeyWindow ?? false }

    /// What is showing below the field.
    public var mode: HUDMode { content.mode }

    /// How loud the microphone was last, 0 to 1.
    public var level: Float { content.levels.last ?? 0 }

    /// Whether a command is under way and the bar is showing it (so it can't be typed into, or put away).
    private var isBusy: Bool { sessionActive && content.mode.isInFlight }

    // MARK: Opening and closing it

    /// Opens the bar with the field ready for typing. While a command is under way there is nothing to type into; the bar says so.
    public func open() {
        cancelPendingHide()
        if isBusy {
            model.note = L10n.Bar.busyNote
            present(takingKeyboard: false)
            return
        }
        visibilityGeneration += 1
        sessionActive = false
        content.resetSession()
        content.mode = .idle
        // A bar that is already the person's keeps what they had typed; one that wasn't starts empty.
        if !model.isOpen { model.text = "" }
        model.note = nil
        model.isOpen = true
        present(takingKeyboard: true)
    }

    /// Puts the bar away, and forgets what was typed. What a command is showing stays until that is over: a question that is waiting
    /// is never taken off the screen.
    public func close() {
        model.isOpen = false
        model.reset()
        removeUnlessShowingACommand()
    }

    public func toggle() {
        if isVisible { close() } else { open() }
    }

    /// Gives the keyboard back to the app that had it before the bar took it, because a command is starting and may type in it. A bar
    /// that isn't listening stops being the person's, and only shows the command; a listening one stays, where it can be seen.
    public func releaseKeyboard() {
        if !keepsOpen() { model.isOpen = false }
        refreshPresentation()
        giveBackKeyboard()
        // With no command to show and nobody holding it open, there is nothing left for the bar to be.
        if !model.isOpen, !sessionActive { removeUnlessShowingACommand() }
    }

    /// Takes the panel off the screen now, unless a command is being shown in it: then only the bar's own part goes.
    private func removeUnlessShowingACommand() {
        guard let panel, panel.isVisible else { return }
        if isBusy {
            refreshPresentation()
            giveBackKeyboard()
            return
        }
        cancelPendingHide()
        visibilityGeneration += 1
        sessionActive = false
        let hadKeyboard = panel.isKeyWindow
        panel.orderOut(nil)
        panel.alphaValue = 1
        content.resetSession()
        content.mode = .idle
        if hadKeyboard, activation.isActive { activation.deactivate() }
    }

    private func giveBackKeyboard() {
        guard let panel, panel.isKeyWindow else { return }
        if activation.isActive { activation.deactivate() }
        // Not active any more, so not key: the app that was in front has the keyboard again. If nothing took the panel's key status
        // with it, it is taken away here, by putting the panel back without the keyboard.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: HUDPresenting

    public var hotkeyHint: String? {
        get { content.hotkeyHint }
        set { content.hotkeyHint = newValue }
    }

    public var onRecovery: ((RecoveryAction) -> Void)? {
        get { content.onRecovery }
        set { content.onRecovery = newValue }
    }

    public var onConfirmationChoice: ((ConfirmationChoice) -> Void)? {
        get { content.onConfirmationChoice }
        set { content.onConfirmationChoice = newValue }
    }

    public func beginSession() {
        content.resetSession()
        model.note = nil
        show(.preparing)
    }

    public func show(_ mode: HUDMode) {
        cancelPendingHide()
        visibilityGeneration += 1
        sessionActive = true
        content.mode = mode
        present(takingKeyboard: false)
        // A question is never a place a keystroke can land: whatever had the keyboard gives it up as the question appears.
        if case .confirm = mode { giveBackKeyboard() }
        announce(mode)
    }

    public func setTranscript(_ text: String, isFinal: Bool) {
        content.transcript = text
        content.isTranscriptFinal = isFinal
    }

    public func push(level: AudioLevel) {
        content.push(level: level)
    }

    public func setConfirmationKeysEnabled(_ enabled: Bool) {
        content.confirmationKeysEnabled = enabled
    }

    public func setAnswerStatus(_ status: AnswerStatus) {
        content.answerStatus = status
    }

    /// What a command had to say is over, now or after `delay`: the bar goes back to waiting for a command if the person has it open (or
    /// the microphone is on), and goes away if it was only showing the command.
    public func hide(after delay: Duration?) {
        cancelPendingHide()
        guard let delay else {
            finishSession()
            return
        }
        let generation = visibilityGeneration
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, generation == visibilityGeneration else { return }
            finishSession()
        }
    }

    // MARK: Window

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func finishSession() {
        visibilityGeneration += 1
        sessionActive = false
        model.note = nil
        guard let panel, panel.isVisible else { return }
        if model.isOpen || keepsOpen() {
            model.isOpen = true
            content.resetSession()
            content.mode = .idle
            refreshPresentation()
        } else {
            model.reset()
            fadeOut()
        }
    }

    /// What the panel accepts: the keyboard only while the bar is the person's and nothing is under way; clicks while it is theirs, or
    /// while a button is showing, and otherwise they pass through to the app underneath.
    private func refreshPresentation() {
        guard let panel else { return }
        panel.allowsKey = model.isOpen && content.mode.allowsTyping
        panel.ignoresMouseEvents = !(model.isOpen || content.mode.isInteractive)
    }

    private func present(takingKeyboard: Bool) {
        let panel = self.panel ?? makePanel()
        let appearing = !panel.isVisible
        if appearing {
            anchorScreen = screenUnderPointer()
            panel.alphaValue = 0
        }
        refreshPresentation()
        reposition(panel)
        if takingKeyboard {
            panel.makeKeyAndOrderFront(nil)
            model.requestFocus()
        } else {
            panel.orderFrontRegardless()
        }
        // A fade-out may be mid-flight; snap back to fully opaque.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.12 : 0
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.visibilityGeneration else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.alphaValue = 1
                    self.content.mode = .idle
                }
            }
        )
    }

    private func makePanel() -> CommandBarPanel {
        let panel = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: CommandBarView.width, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.model = model
        panel.onBecomeKey = { [weak self] in
            guard let self else { return }
            if !activation.isActive { activation.activate() }
            model.requestFocus()
        }
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "Voxa"

        // A plain hosting view whose sizing is switched off: SwiftUI must never drive the window frame through Auto Layout (see
        // `CommandBarView.init`). The view reports its size and `contentSizeDidChange` resizes the panel.
        let host = NSHostingView(
            rootView: CommandBarView(model: model, content: content) { [weak self] size in
                self?.contentSizeDidChange(size)
            }
        )
        host.sizingOptions = []
        panel.contentView = host
        // A hosting view reports a zero fitting size until it has been laid out once.
        host.layoutSubtreeIfNeeded()
        if host.fittingSize.width > 0 {
            panel.setContentSize(host.fittingSize)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }
        self.panel = panel
        return panel
    }

    /// The person clicked somewhere else: put the bar away, unless it is listening (or has stopped being theirs to put away).
    private func panelResignedKey() {
        guard isVisible, model.isOpen, !keepsOpen() else { return }
        close()
    }

    /// Resizes the panel to its content, keeping the top edge pinned. Runs on its own main-actor turn, outside any layout pass.
    func contentSizeDidChange(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let target = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        if panel.contentRect(forFrameRect: panel.frame).size != target {
            panel.setContentSize(target)
            panel.invalidateShadow()
        }
        // Always re-pin: the size may already have been right while the origin was computed from a stale one.
        reposition(panel)
    }

    /// The panel's current frame, for tests and diagnostics.
    var panelFrame: NSRect? { panel?.frame }
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }
    /// Whether clicks pass through the panel to the app underneath.
    var panelIgnoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }
    var panelCanBecomeKey: Bool { panel?.canBecomeKey ?? false }
    /// The panel's window, for tests.
    var window: NSWindow? { panel }
    /// The visible frame of the screen the bar is anchored to, for tests.
    var anchorVisibleFrame: NSRect? { anchorScreen?.visibleFrame }

    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Top centre of the anchor screen, just below the menu bar.
    private func reposition(_ panel: CommandBarPanel) {
        guard let visible = (anchorScreen ?? screenUnderPointer())?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - size.height - 14).rounded()
        )
        #if DEBUG
        // An automated test run keeps its windows well off every screen, so it never gets in the way of whoever is using the Mac.
        if ProcessInfo.processInfo.environment["VOXA_DEBUG_PANELS_OFFSCREEN"] != nil { origin.x -= 30_000 }
        #endif
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func announce(_ mode: HUDMode) {
        let message: String? =
            switch mode {
            case .listening: L10n.HUD.listening
            case .result(let text): text
            case .notice(let title, _): title
            case .error(let error): error.title
            case .confirm(let prompt): L10n.HUD.confirmAnnouncement(prompt.title, prompt.summary)
            case .reply(let text): text
            case .idle, .preparing, .transcribing, .thinking, .acting: nil
            }
        if let message {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

#if DEBUG
extension CommandBarController {
    /// The panel, for tests in other modules. Debug builds only.
    public var debugWindow: NSWindow? { panel }

    /// Puts a whole level meter on the bar at once. Debug builds only.
    public func debugFillMeter(_ levels: [Float]) {
        content.debugFillMeter(levels)
    }

    /// Presses a confirmation button as a click would. Debug builds only.
    public func pressConfirmationButton(_ choice: ConfirmationChoice) {
        content.onConfirmationChoice?(choice)
    }

    /// Presses the recovery button of the error on screen, as a click would. Debug builds only.
    public func pressRecoveryButton() {
        if case .error(let error) = content.mode, let recovery = error.recovery { content.onRecovery?(recovery) }
    }

    /// What a shell wants to know about the bar: whether it is showing and what, whether it can take typing, and whether it is the
    /// person's. Debug builds only.
    public var debugSummary: String {
        "bar=\(isVisible ? "visible" : "hidden") barKey=\(isPanelKey) barText=\(model.text.isEmpty ? "empty" : "typed") "
            + "barNote=\(model.note == nil ? "none" : "shown") barMode=\(content.mode.debugName) barOpen=\(model.isOpen) "
            + "barCanKey=\(panelCanBecomeKey) barClicks=\(!panelIgnoresMouseEvents)"
    }
}

extension HUDMode {
    /// A short stable name, which a shell can read.
    var debugName: String {
        switch self {
        case .idle: "idle"
        case .preparing: "preparing"
        case .listening: "listening"
        case .transcribing: "transcribing"
        case .result: "result"
        case .notice: "notice"
        case .error: "error"
        case .thinking: "thinking"
        case .acting: "acting"
        case .confirm: "confirm"
        case .reply: "reply"
        }
    }
}
#endif
