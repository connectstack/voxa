import Foundation
import Observation

/// The one switch on the Safety tab that gets a second thought: full control. Turning it on asks first, so an accidental click
/// can't do it; turning it off is immediate, because leaving it on is the only way it can hurt.
@MainActor
@Observable
final class SafetyModel {
    /// Whether the question "Give Voxa full control?" is up.
    var isAsking = false

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    var fullControl: Bool { store.current.fullControl }

    /// What flipping the switch does: off is immediate, on brings up the question and changes nothing until it is answered.
    func setFullControl(_ on: Bool) {
        if on {
            if !store.current.fullControl { isAsking = true }
        } else {
            isAsking = false
            store.current.fullControl = false
        }
    }

    /// "Give Full Control".
    func giveFullControl() {
        isAsking = false
        store.current.fullControl = true
    }

    /// "Keep Asking", or Esc.
    func keepAsking() {
        isAsking = false
    }
}
