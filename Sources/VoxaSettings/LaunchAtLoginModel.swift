import Foundation
import Observation
import VoxaCore

/// The state behind the "Start Voxa when I log in" switch.
@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var isEnabled: Bool
    private(set) var needsApproval: Bool
    private(set) var error: String?

    @ObservationIgnored private let control: any LaunchAtLoginControlling

    init(control: any LaunchAtLoginControlling) {
        self.control = control
        isEnabled = control.isEnabled
        needsApproval = control.needsApproval
    }

    /// Reads the system's answer again, since the user can change it in System Settings.
    func refresh() {
        isEnabled = control.isEnabled
        needsApproval = control.needsApproval
    }

    func set(_ enabled: Bool) {
        do {
            try control.setEnabled(enabled)
            error = nil
        } catch {
            self.error = L10n.GeneralUI.startupFailed(error.localizedDescription)
        }
        refresh()
    }

    func openLoginItemsSettings() {
        control.openLoginItemsSettings()
    }

    /// What the switch shows: on when it is registered, even while macOS is still waiting for approval.
    var switchIsOn: Bool { isEnabled || needsApproval }
}
