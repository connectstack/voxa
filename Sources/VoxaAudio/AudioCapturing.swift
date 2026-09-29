import Foundation
import VoxaCore

/// The two streams produced by an active capture. Both finish when `AudioCapturing.stop()` is called
/// (or the capture fails; `chunks` then finishes by throwing).
public struct AudioCaptureStreams: Sendable {
    /// Canonical 16 kHz mono audio, in order, unbounded (a push-to-talk utterance is short).
    public let chunks: AsyncThrowingStream<AudioChunk, any Error>
    /// Smoothed input levels for the HUD meter. Only the newest value is retained if the consumer is slow.
    public let levels: AsyncStream<AudioLevel>

    public init(chunks: AsyncThrowingStream<AudioChunk, any Error>, levels: AsyncStream<AudioLevel>) {
        self.chunks = chunks
        self.levels = levels
    }
}

/// A source of microphone audio. Push-to-talk maps directly onto it: key down → `start()`, key up → `stop()`.
public protocol AudioCapturing: Sendable {
    /// Begins capturing. Throws a `UserFacingConvertible` error when the microphone is unavailable or not authorized.
    func start() async throws -> AudioCaptureStreams
    /// Stops capturing and finishes both streams. Safe to call when idle and safe to call repeatedly.
    func stop() async
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphoneNotAuthorized(PermissionStatus)
    case noInputDevice
    case engineStartFailed(String)
    case deviceLost
    case unsupportedFormat(String)
    case fileUnreadable(String)
}

extension AudioCaptureError: UserFacingConvertible {
    public var userFacing: UserFacingError {
        switch self {
        case .microphoneNotAuthorized(let status):
            .permissionRequired(.microphone, status: status)
        case .noInputDevice:
            UserFacingError(title: L10n.Errors.noInputDeviceTitle, detail: L10n.Errors.noInputDeviceDetail)
        case .engineStartFailed(let reason):
            UserFacingError(title: L10n.Errors.micStartFailedTitle, detail: L10n.Errors.micStartFailedDetail(reason))
        case .deviceLost:
            UserFacingError(title: L10n.Errors.micLostTitle, detail: L10n.Errors.micLostDetail)
        case .unsupportedFormat(let reason), .fileUnreadable(let reason):
            UserFacingError(title: L10n.Errors.micStartFailedTitle, detail: L10n.Errors.micStartFailedDetail(reason))
        }
    }
}
