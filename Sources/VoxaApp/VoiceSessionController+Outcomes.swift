import Foundation
import VoxaCore
import VoxaHUD

/// How a command ends: the reply, a notice, an error, or nothing, and how the HUD is dismissed afterwards.
extension VoiceSessionController {
    // MARK: Outcomes

    func complete(_ run: Run, transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(run)
        phase = .idle

        if run.kind == .answer {
            if text.isEmpty {
                hud.setAnswerStatus(.unclear)
            } else {
                confirmations?.submitSpokenAnswer(text)
            }
            return
        }

        guard !text.isEmpty else {
            hud.show(
                .notice(
                    title: L10n.HUD.didntCatch,
                    detail: hotkeys.pushToTalkDescription.map(L10n.HUD.didntCatchDetail)
                )
            )
            hud.hide(after: configuration.noticeDisplay)
            armDismiss(for: configuration.noticeDisplay)
            return
        }

        Log.session.info("command recognized (\(text.count) characters)")
        #if DEBUG
        DebugTranscriptDump.write(text)
        #endif
        hud.setTranscript(text, isFinal: true)
        if let agent {
            startAgent(agent, command: text)
            return
        }
        hud.show(.result(text))
        hud.hide(after: configuration.resultDisplay)
        armDismiss(for: configuration.resultDisplay)
    }

    func fail(_ run: Run, with error: UserFacingError) {
        guard run.isActive else { return }
        finish(run)
        if run.kind == .answer {
            // The prompt stays up and its buttons still work; only the spoken answer failed.
            Log.session.error("could not record a spoken answer: \(error.title, privacy: .public)")
            phase = .idle
            hud.setAnswerStatus(.unclear)
            return
        }
        presentFailure(error)
    }

    func presentFailure(_ error: UserFacingError) {
        lastError = error
        phase = .failed
        Log.session.error("command failed: \(error.title, privacy: .public)")

        hud.show(.error(error))
        hud.hide(after: configuration.errorDisplay)
        armDismiss(for: configuration.errorDisplay)

        errorResetTask?.cancel()
        errorResetTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: configuration.errorDisplay)
            guard !Task.isCancelled, phase == .failed else { return }
            phase = .idle
        }
    }

    /// Permission was just granted but the key is already up: say so instead of silently doing nothing.
    func announceReady(_ run: Run) {
        finish(run)
        phase = .idle
        if run.kind == .answer {
            hud.setAnswerStatus(.idle)
            return
        }
        hud.show(
            .notice(
                title: L10n.HUD.allSet,
                detail: hotkeys.pushToTalkDescription.map(L10n.HUD.allSetDetail)
            )
        )
        hud.hide(after: configuration.noticeDisplay)
        armDismiss(for: configuration.noticeDisplay)
    }

    /// The shortcut was tapped rather than held. Push-to-talk needs a hold, and a first-time user's natural move is a
    /// tap, so say how it works instead of letting the HUD flash and vanish.
    func tapped(_ run: Run) {
        Log.session.notice("shortcut released too soon; showing the hold-to-talk hint")
        finish(run)
        phase = .idle
        if run.kind == .answer {
            hud.setAnswerStatus(.idle)
            return
        }
        hud.show(
            .notice(
                title: L10n.HUD.holdToTalk,
                detail: hotkeys.pushToTalkDescription.map(L10n.HUD.holdToTalkDetail)
            )
        )
        hud.hide(after: configuration.noticeDisplay)
        armDismiss(for: configuration.noticeDisplay)
    }

    /// Tears down everything a run owns. Safe to call more than once. Does not cancel `run.task`, because this is
    /// usually called from inside it.
    func finish(_ run: Run) {
        guard !run.isFinished else { return }
        run.isFinished = true
        run.cancelHelpers()
        let capture = capture
        Task { await capture.stop() }
    }

    // MARK: Esc while a result is showing

    /// Binds Esc to "dismiss the HUD" for as long as `duration`, so Esc is only ever captured while there is
    /// something on screen to dismiss.
    func armDismiss(for duration: Duration, keeping existing: Task<Void, Never>? = nil) {
        disarmDismiss()
        if let existing {
            // Carry on with the Esc listener the command already had, rather than dropping it and registering it again.
            dismissWatcher = existing
        } else {
            let presses = hotkeys.cancelKeyPresses()
            dismissWatcher = Task { [weak self] in
                for await _ in presses {
                    self?.cancel()
                    return
                }
            }
        }
        dismissDisarm = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled else { return }
            disarmDismiss()
        }
    }

    func disarmDismiss() {
        dismissWatcher?.cancel()
        dismissDisarm?.cancel()
        dismissWatcher = nil
        dismissDisarm = nil
    }

    func handleRecovery(_ action: RecoveryAction) {
        switch action {
        case .openSystemSettings(let kind):
            permissions.openSystemSettings(for: kind)
        case .openAppSettings:
            openAppSettings()
        case .openModelSettings:
            openModelSettings()
        case .openOllama:
            openOllama()
        case .retry:
            break
        }
        disarmDismiss()
        hud.hide(after: nil)
    }
}
