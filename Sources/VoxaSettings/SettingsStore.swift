import Foundation
import Observation
import VoxaCore

/// The persisted, observable home of `AppSettings`. SwiftUI binds to `current`; services read it through
/// `SettingsProviding` (always on the main actor) and take a value-type snapshot before doing background work.
@MainActor
@Observable
public final class SettingsStore: SettingsProviding {
    /// The single `UserDefaults` key holding the JSON-encoded settings.
    public static let defaultsKey = "voxa.settings"

    public var current: AppSettings {
        didSet {
            guard current != oldValue else { return }
            persist()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.current = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(current), forKey: Self.defaultsKey)
        } catch {
            Log.settings.error("could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
