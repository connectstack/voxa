import Foundation
import Testing
import VoxaCore
@testable import VoxaSettings

@MainActor
private final class FakeLogin: LaunchAtLoginControlling {
    var isEnabled = false
    var needsApproval = false
    var failure: (any Error)?
    private(set) var openedSettings = 0
    /// What macOS says after a registration: it may want the user's approval first.
    var approvalRequired = false

    func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        if enabled {
            isEnabled = !approvalRequired
            needsApproval = approvalRequired
        } else {
            isEnabled = false
            needsApproval = false
        }
    }

    func openLoginItemsSettings() { openedSettings += 1 }
}

@MainActor
@Suite("Start at login")
struct LaunchAtLoginModelTests {
    @Test("the switch follows the system's answer, and turning it on and off is passed on")
    func toggles() {
        let control = FakeLogin()
        let model = LaunchAtLoginModel(control: control)
        #expect(!model.switchIsOn)

        model.set(true)
        #expect(model.switchIsOn && control.isEnabled)
        model.set(false)
        #expect(!model.switchIsOn && !control.isEnabled)
    }

    @Test("when macOS wants approval, the switch stays on and points at Login Items")
    func needsApproval() {
        let control = FakeLogin()
        control.approvalRequired = true
        let model = LaunchAtLoginModel(control: control)
        model.set(true)
        #expect(model.switchIsOn)
        #expect(model.needsApproval && !model.isEnabled)
        model.openLoginItemsSettings()
        #expect(control.openedSettings == 1)
    }

    @Test("a failure is put in plain words and the switch shows what is really so")
    func failure() {
        struct Denied: Error, LocalizedError { var errorDescription: String? { "Operation not permitted." } }
        let control = FakeLogin()
        control.failure = Denied()
        let model = LaunchAtLoginModel(control: control)
        model.set(true)
        #expect(model.error == L10n.GeneralUI.startupFailed("Operation not permitted."))
        #expect(!model.switchIsOn)

        control.failure = nil
        model.set(true)
        #expect(model.error == nil && model.switchIsOn)
    }

    @Test("a change made in System Settings shows up on the next look")
    func refresh() {
        let control = FakeLogin()
        let model = LaunchAtLoginModel(control: control)
        control.isEnabled = true
        model.refresh()
        #expect(model.switchIsOn)
    }
}
