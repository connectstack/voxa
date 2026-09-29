import AppKit
import SwiftUI
import VoxaCore

/// A borderless, non-activating panel. It floats above other windows (including full-screen apps) and can be shown
/// without taking keyboard focus from the frontmost app; it only becomes key when a prompt needs typed input.
final class HUDPanel: NSPanel {
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Owns the HUD window and its `HUDModel`, and implements what the session coordinator needs from it.
@MainActor
public final class HUDController: HUDPresenting {
    private let model: HUDModel
    private let clock: any Clock<Duration>

    private var panel: HUDPanel?
    /// The screen the HUD appeared on. Fixed while it stays on screen so it doesn't hop between displays as the
    /// pointer moves.
    private var anchorScreen: NSScreen?
    private var hideTask: Task<Void, Never>?
    /// Bumped on every show/hide so a stale fade-out or delayed hide can tell it has been superseded.
    private var visibilityGeneration = 0

    public var hotkeyHint: String? {
        get { model.hotkeyHint }
        set { model.hotkeyHint = newValue }
    }

    public var onRecovery: ((RecoveryAction) -> Void)? {
        get { model.onRecovery }
        set { model.onRecovery = newValue }
    }

    public var onConfirmationChoice: ((ConfirmationChoice) -> Void)? {
        get { model.onConfirmationChoice }
        set { model.onConfirmationChoice = newValue }
    }

    public init(model: HUDModel = HUDModel(), clock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        self.clock = clock
    }

    // MARK: HUDPresenting

    public func beginSession() {
        model.resetSession()
        show(.preparing)
    }

    public func show(_ mode: HUDMode) {
        cancelPendingHide()
        visibilityGeneration += 1
        model.mode = mode
        present(interactive: mode.isInteractive)
        announce(mode)
    }

    public func setTranscript(_ text: String, isFinal: Bool) {
        model.transcript = text
        model.isTranscriptFinal = isFinal
    }

    public func push(level: AudioLevel) {
        model.push(level: level)
    }

    public func setConfirmationKeysEnabled(_ enabled: Bool) {
        model.confirmationKeysEnabled = enabled
    }

    public func setAnswerStatus(_ status: AnswerStatus) {
        model.answerStatus = status
    }

    public func hide(after delay: Duration?) {
        cancelPendingHide()
        guard let delay else {
            fadeOut()
            return
        }
        let generation = visibilityGeneration
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, generation == visibilityGeneration else { return }
            fadeOut()
        }
    }

    // MARK: Window

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func present(interactive: Bool) {
        let panel = self.panel ?? makePanel()
        panel.ignoresMouseEvents = !interactive

        if !panel.isVisible {
            anchorScreen = screenUnderPointer()
        }
        reposition(panel)

        if panel.isVisible {
            // A fade-out may be mid-flight; snap back to fully opaque.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
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
                }
            }
        )
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Voxa"

        // A plain hosting view whose sizing is switched off: SwiftUI must never drive the window frame through Auto
        // Layout (see `HUDView.init`). The view reports its size and `contentSizeDidChange` resizes the panel.
        let host = NSHostingView(
            rootView: HUDView(model: model) { [weak self] size in
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

        self.panel = panel
        return panel
    }

    /// Resizes the panel to its content, keeping the top edge pinned. Runs on its own main-actor turn, outside any
    /// layout pass.
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
    var isPanelVisible: Bool { panel?.isVisible ?? false }
    /// Whether clicks pass through the panel to the app underneath (true except while a button is showing).
    var panelIgnoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }
    var panelCanBecomeKey: Bool { panel?.canBecomeKey ?? false }
    /// The visible frame of the screen the HUD is anchored to, for tests.
    var anchorVisibleFrame: NSRect? { anchorScreen?.visibleFrame }

    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Top-center of the anchor screen, just below the menu bar.
    private func reposition(_ panel: HUDPanel) {
        guard let visible = (anchorScreen ?? screenUnderPointer())?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - size.height - 14).rounded()
        )
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
            case .preparing, .transcribing, .thinking, .acting: nil
            }
        if let message {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

#if DEBUG
extension HUDController {
    /// Presses a confirmation button as a click would. Debug builds only.
    public func pressConfirmationButton(_ choice: ConfirmationChoice) {
        model.onConfirmationChoice?(choice)
    }

    /// Presses the recovery button of the error on screen, as a click would. Debug builds only.
    public func pressRecoveryButton() {
        if case .error(let error) = model.mode, let recovery = error.recovery { model.onRecovery?(recovery) }
    }
}
#endif
