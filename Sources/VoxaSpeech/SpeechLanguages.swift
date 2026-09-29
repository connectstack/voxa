import Foundation
import Speech

/// A recognition language offered in Settings.
public struct SpeechLanguage: Identifiable, Hashable, Sendable {
    /// Locale identifier, e.g. `en_US`.
    public let id: String
    public let name: String
    /// Whether the classic recognizer can run this language fully on-device.
    public let supportsOnDevice: Bool

    public init(id: String, name: String, supportsOnDevice: Bool) {
        self.id = id
        self.name = name
        self.supportsOnDevice = supportsOnDevice
    }
}

public enum SpeechLanguages {
    /// Languages the system can recognize, sorted by their display name.
    public static func available() -> [SpeechLanguage] {
        SFSpeechRecognizer.supportedLocales()
            .map { locale in
                SpeechLanguage(
                    id: locale.identifier,
                    name: locale.voxaDisplayName,
                    supportsOnDevice: SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
