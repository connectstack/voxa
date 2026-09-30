import Foundation
import VoxaHUD

/// Stands in for making Voxa the active app and giving that up again, so a test of the Voxa bar's window never changes which app is
/// active for every other window in the test process.
@MainActor
public final class FakeKeyboardActivation: KeyboardActivating {
    public private(set) var isActive = false
    public private(set) var activations = 0
    public private(set) var deactivations = 0

    public init() {}

    public func activate() {
        isActive = true
        activations += 1
    }

    public func deactivate() {
        isActive = false
        deactivations += 1
    }
}
