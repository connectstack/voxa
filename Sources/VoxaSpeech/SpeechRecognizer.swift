import Foundation
import VoxaCore

/// One snapshot of a transcription in progress.
///
/// A recognizer's stream yields zero or more partial transcripts (`isFinal == false`), each holding the *whole*
/// hypothesis so far (not a delta), followed by exactly one final transcript and then finishes. Silence produces a
/// single final transcript with empty text; that is a normal outcome, not an error.
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    /// 0…1 when the engine reports it (only ever set on final transcripts).
    public var confidence: Float?

    public init(text: String, isFinal: Bool, confidence: Float? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// Speech-to-text over a stream of canonical audio chunks.
public protocol SpeechRecognizer: Sendable {
    /// System permissions this engine needs to transcribe `locale` right now. The session requests them before
    /// opening the microphone so the user sees one clear prompt sequence instead of a mid-command failure.
    func requiredPermissions(locale: Locale) async -> Set<PermissionKind>

    /// Makes the engine ready for `locale` (downloads or warms a model). Cheap when already prepared.
    func prepare(locale: Locale) async throws

    /// Streams transcripts for `audio`. Cancelling the consuming task stops recognition. If `audio` throws, the
    /// error is rethrown after recognition is torn down. Failures are `UserFacingConvertible`.
    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error>
}

/// Chooses the recognizer for the current settings. A protocol so the session can be tested with scripted recognizers.
public protocol SpeechRecognizerProviding: Sendable {
    func recognizer(for settings: AppSettings) -> any SpeechRecognizer
}

public enum SpeechError: Error, Sendable, Equatable {
    case notAuthorized(PermissionStatus)
    case unsupportedLocale(String)
    case onDeviceUnavailable(languageName: String)
    case recognizerUnavailable
    case recognitionFailed(String)
    case modelDownloadFailed(String)
}

extension SpeechError: UserFacingConvertible {
    public var userFacing: UserFacingError {
        switch self {
        case .notAuthorized(let status):
            .permissionRequired(.speechRecognition, status: status)
        case .unsupportedLocale:
            UserFacingError(
                title: L10n.Errors.unsupportedLanguageTitle,
                detail: L10n.Errors.unsupportedLanguageDetail,
                recovery: .openAppSettings
            )
        case .onDeviceUnavailable(let languageName):
            UserFacingError(
                title: L10n.Errors.onDeviceUnavailableTitle(languageName),
                detail: L10n.Errors.onDeviceUnavailableDetail,
                recovery: .openAppSettings
            )
        case .recognizerUnavailable:
            UserFacingError(
                title: L10n.Errors.recognizerUnavailableTitle,
                detail: L10n.Errors.recognizerUnavailableDetail
            )
        case .recognitionFailed(let reason):
            UserFacingError(
                title: L10n.Errors.recognitionFailedTitle,
                detail: L10n.Errors.recognitionFailedDetail(reason)
            )
        case .modelDownloadFailed(let reason):
            UserFacingError(
                title: L10n.Errors.modelDownloadFailedTitle,
                detail: L10n.Errors.modelDownloadFailedDetail(reason)
            )
        }
    }
}

extension Locale {
    /// The locale's name in the user's language, e.g. "English (India)". Falls back to the identifier.
    var voxaDisplayName: String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
