import Testing
@testable import VoxaCore

@Suite("L10n")
struct L10nTests {
    @Test("interpolated strings contain their arguments and no unresolved placeholders")
    func interpolation() {
        let samples = [
            L10n.HUD.releaseToSend("⌥Space"),
            L10n.HUD.didntCatchDetail("⌥Space"),
            L10n.HUD.allSetDetail("⌥Space"),
            L10n.Menu.ready("⌥Space"),
            L10n.Errors.onDeviceUnavailableTitle("English (India)"),
        ]
        for sample in samples {
            #expect(!sample.contains("%@"), "unresolved placeholder in: \(sample)")
            #expect(!sample.contains("%lld"), "unresolved placeholder in: \(sample)")
        }
        #expect(L10n.HUD.releaseToSend("⌥Space").contains("⌥Space"))
        #expect(L10n.Errors.onDeviceUnavailableTitle("English (India)").contains("English (India)"))
    }

    @Test("no user-facing string is empty")
    func nonEmpty() {
        let strings = [
            L10n.HUD.preparing, L10n.HUD.listening, L10n.HUD.transcribing, L10n.HUD.heard, L10n.HUD.placeholder,
            L10n.HUD.escapeKeyLabel, L10n.HUD.cancelHint, L10n.HUD.didntCatch, L10n.HUD.allSet,
            L10n.Menu.listening, L10n.Menu.thinking, L10n.Menu.acting, L10n.Menu.problem, L10n.Menu.settings, L10n.Menu.quit,
            L10n.Settings.windowTitle, L10n.Settings.pushToTalk, L10n.Settings.speechEngine, L10n.Settings.language,
            L10n.Recovery.openSystemSettings, L10n.Recovery.openAppSettings, L10n.Recovery.retry,
            L10n.Errors.genericTitle, L10n.Errors.noInputDeviceTitle, L10n.Errors.noInputDeviceDetail,
        ]
        for string in strings {
            #expect(!string.isEmpty)
        }
    }

    @Test("recovery actions have button titles")
    func recoveryTitles() {
        #expect(RecoveryAction.openSystemSettings(.microphone).title == L10n.Recovery.openSystemSettings)
        #expect(RecoveryAction.openAppSettings.title == L10n.Recovery.openAppSettings)
        #expect(RecoveryAction.openModelSettings.title == L10n.Recovery.openAppSettings)
        #expect(RecoveryAction.openOllama.title == L10n.Recovery.openOllama)
        #expect(RecoveryAction.retry.title == L10n.Recovery.retry)
    }
}
