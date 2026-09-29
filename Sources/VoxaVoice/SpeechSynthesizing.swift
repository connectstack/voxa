import Foundation
import VoxaCore

/// One of the voices the system can speak with.
public struct VoiceInfo: Sendable, Equatable, Hashable, Identifiable {
    /// How natural it sounds. Better ones are a download away in System Settings → Accessibility → Spoken Content.
    public enum Quality: Int, Sendable, Comparable {
        case standard
        case enhanced
        case premium

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The system's identifier for the voice, which is what Settings stores.
    public var id: String
    public var name: String
    /// A language tag such as `en-US`.
    public var language: String
    public var quality: Quality

    public init(id: String, name: String, language: String, quality: Quality = .standard) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

/// How one thing is to be said.
public struct SpeechOptions: Sendable, Equatable {
    /// A specific voice, or nil for the best one installed for `language`.
    public var voiceIdentifier: String?
    /// The language of what is being said, as a locale identifier (`en_IN`) or a tag (`en-IN`).
    public var language: String?
    /// In `AVSpeechUtterance`'s units; see `AppSettings.speechRateRange`.
    public var rate: Double

    public init(voiceIdentifier: String? = nil, language: String? = nil, rate: Double = AppSettings.defaultSpeechRate) {
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        self.rate = rate
    }
}

/// Speaks text aloud. `@MainActor` because the system's synthesizer is driven from the main thread and the results drive UI.
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    /// Says `text`. Anything already being said is cut off first, so a new answer never waits behind an old one.
    func speak(_ text: String, options: SpeechOptions)
    /// Stops at once, mid-word.
    func stop()
    func voices() -> [VoiceInfo]
}
