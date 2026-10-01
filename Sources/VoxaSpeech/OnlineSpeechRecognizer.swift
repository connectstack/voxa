import Foundation
import Network
import VoxaCore

/// Whether the Mac has a network connection right now, kept up to date in the background.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// True until the system says otherwise, so that a command spoken a moment after launch isn't sent the offline way for nothing.
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.rohitsainier.voxa.network", qos: .utility))
    }

    var isOnline: Bool { lock.withLock { online } }
}

/// "Apple online" recognition: Apple's servers, the recognition Siri and Dictation use, which hears names and accents better than the
/// on-device models do. With no network it is the on-device engine instead, so that the microphone never goes quiet on a train.
///
/// The choice is made when the audio starts, because audio can only be given to one engine: a connection that drops in the middle of a
/// command is the recognizer's own error to report, with the words heard so far.
public struct OnlineSpeechRecognizer: SpeechRecognizer {
    private let online: any SpeechRecognizer
    private let fallback: any SpeechRecognizer
    private let isOnline: @Sendable () -> Bool

    /// - Parameters:
    ///   - online: The engine that sends the voice to Apple.
    ///   - fallback: The engine that keeps it on this Mac, for when there is no network.
    public init(online: any SpeechRecognizer, fallback: any SpeechRecognizer) {
        self.init(online: online, fallback: fallback, isOnline: { NetworkStatus.shared.isOnline })
    }

    /// `isOnline` says whether there is a network now; a test brings its own.
    init(online: any SpeechRecognizer, fallback: any SpeechRecognizer, isOnline: @escaping @Sendable () -> Bool) {
        self.online = online
        self.fallback = fallback
        self.isOnline = isOnline
    }

    /// What the online engine needs, whether or not it ends up used: the permission is asked for once, before the microphone opens.
    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        await online.requiredPermissions(locale: locale)
    }

    public func prepare(locale: Locale) async throws {
        try await online.prepare(locale: locale)
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        guard isOnline() else {
            Log.speech.info("no network; recognizing on this Mac instead of online")
            return fallback.transcribe(audio, locale: locale)
        }
        Log.speech.info("recognizing online, on Apple's servers")
        return online.transcribe(audio, locale: locale)
    }
}
