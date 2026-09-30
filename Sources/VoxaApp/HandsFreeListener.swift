import Foundation
import Observation
import VoxaAudio
import VoxaCore
import VoxaPermissions
import VoxaSpeech

/// What continuous listening asks of the rest of the app.
@MainActor
public protocol HandsFreeHost: AnyObject {
    var handsFreeAvailability: HandsFreeAvailability { get }
    /// Carries out a command that was given without the shortcut key: typed, said to the microphone, or handed over by Siri.
    /// False when it can't be taken now.
    @discardableResult func submitCommand(_ command: String) -> Bool
}

/// Listens continuously, from the moment the microphone button in the Voxa bar is clicked until it is clicked again, and takes what
/// it hears as commands.
///
/// It only ever runs because a person switched it on (it is never a saved setting, so a Mac that restarts comes back with the
/// microphone off), it says so wherever it can (the bar, the menu bar, macOS's own orange dot), and it lets go of the microphone by
/// itself after a stretch of silence. A voice-activity detector cuts what the microphone hears into utterances, and each one is
/// turned into text on this Mac and handed to the session as if it had been held-to-talk, so it meets the same policy, confirmations
/// and refusals. Answering a confirmation is not something a voice can do: the microphone is closed for as long as a command is being
/// carried out or spoken about, and a question waits for a click, the chord, or the shortcut held.
///
/// The microphone is closed whenever Voxa is not idle (a held key, a command running, a reply being spoken) so it never hears Voxa,
/// and opens again a moment after that is over; the listening carries on from there.
///
/// Time here is the audio's own: how long the microphone has been listening, so the silence that ends a session is silence that was
/// really heard.
@MainActor
@Observable
public final class HandsFreeListener {
    public typealias State = HandsFreeState

    public struct Configuration: Sendable {
        /// How often it looks at whether the microphone should be open.
        public var poll: Duration = .milliseconds(200)
        /// After Voxa was busy or speaking, how long everything must have been quiet before the microphone opens again.
        public var quietAfterBusy: Duration = .milliseconds(800)
        /// Audio to leave unheard after the microphone opens, for the click an engine makes as it starts.
        public var settle: TimeInterval = 0.3
        /// The longest to wait for an utterance to be turned into text.
        public var transcriptionTimeout: Duration = .seconds(12)
        /// How long to wait before trying again after the microphone or a permission failed.
        public var retry: Duration = .seconds(3)
        /// Utterances waiting to be turned into text. A room that never goes quiet must not build a queue: the oldest is dropped.
        public var backlog = 2
        /// Fewer letters and digits than this (a cough the engine wrote as "uh") is not a command.
        public var minimumCommandLength = 3
        /// For test runs: switch off after this many seconds of silence instead of what Settings says, whatever that is.
        public var idleSecondsOverride: TimeInterval?

        public init() {}
    }

    public internal(set) var state: State = .off
    /// Whether it is switched on: what the bar's microphone button shows.
    public private(set) var isOn = false

    /// Told whenever `state` changes.
    @ObservationIgnored public var onStateChange: (@MainActor (State) -> Void)?
    /// Told why, when it switches itself off.
    @ObservationIgnored public var onStop: (@MainActor (HandsFreeStopReason) -> Void)?
    /// Told how loud the microphone is, while it is open.
    @ObservationIgnored public var onLevel: (@MainActor (AudioLevel) -> Void)?

    private let capture: any AudioCapturing
    private let recognizers: any SpeechRecognizerProviding
    private let permissions: any PermissionsProviding
    private let settings: any SettingsProviding
    /// Held weakly: the session owns the listener's whole life, and if it is gone there is nothing left to listen for.
    private weak var host: (any HandsFreeHost)?
    private let clock: any Clock<Duration>
    private let configuration: Configuration

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var detector: VoiceActivityDetector
    /// Seconds of audio listened to since this started.
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var skipUntil: TimeInterval = 0
    /// When something was last said or done, in `listened` time, for the silence that switches it off.
    @ObservationIgnored private var lastActivity: TimeInterval = 0

    @ObservationIgnored private var backlog: [[Float]] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(
        capture: any AudioCapturing,
        recognizers: any SpeechRecognizerProviding,
        permissions: any PermissionsProviding,
        settings: any SettingsProviding,
        host: any HandsFreeHost,
        clock: any Clock<Duration> = ContinuousClock(),
        configuration: Configuration = Configuration(),
        detector: VoiceActivityDetector = VoiceActivityDetector()
    ) {
        self.capture = capture
        self.recognizers = recognizers
        self.permissions = permissions
        self.settings = settings
        self.host = host
        self.clock = clock
        self.configuration = configuration
        self.detector = detector
    }

    // MARK: Lifecycle

    /// Starts watching for the switch. Call once at launch; the microphone opens only once `setOn(true)` has been called.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Switches continuous listening on or off.
    public func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            lastActivity = listened
            setState(.starting)
        } else {
            reset(to: .off)
        }
    }

    /// Stops for good, and closes the microphone.
    public func stop() async {
        loop?.cancel()
        loop = nil
        worker?.cancel()
        worker = nil
        isOn = false
        await capture.stop()
        reset(to: .off)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: The loop

    private func run() async {
        var quiet: Duration = .zero
        var wasBusy = false
        while !Task.isCancelled {
            guard isOn else {
                if state != .off { reset(to: .off) }
                wasBusy = false
                await pause(configuration.poll)
                continue
            }

            let availability = host?.handsFreeAvailability ?? .working
            guard availability == .ready else {
                if state != .paused(availability) { enterPause(availability) }
                wasBusy = true
                quiet = .zero
                await pause(configuration.poll)
                continue
            }
            // Something that just ended (a reply still being spoken, a key just let go of) is given a moment to be really over.
            if wasBusy, quiet < configuration.quietAfterBusy {
                quiet += configuration.poll
                await pause(configuration.poll)
                continue
            }
            wasBusy = false
            await listen()
        }
    }

    private func pause(_ duration: Duration) async {
        try? await clock.sleep(for: duration)
    }

    /// Whether the microphone should be open: it is switched on and nothing else has need of it.
    private var shouldListen: Bool {
        isOn && host?.handsFreeAvailability == .ready
    }

    private func enterPause(_ availability: HandsFreeAvailability) {
        backlog.removeAll()
        setState(.paused(availability))
    }

    private func reset(to newState: State) {
        backlog.removeAll()
        setState(newState)
    }

    // MARK: Listening

    /// One stretch of the microphone being open, from opening it to its being closed again.
    private func listen() async {
        let snapshot = settings.current
        setState(.starting)

        let recognizer = recognizers.recognizer(for: snapshot)
        let needs = await recognizer.requiredPermissions(locale: snapshot.locale)
        let required = [PermissionKind.microphone] + needs.sorted { $0.rawValue < $1.rawValue }
        if let error = await permissions.ensureGranted(required) {
            return await unavailable(error)
        }
        guard shouldListen else { return }

        let streams: AudioCaptureStreams
        do {
            streams = try await capture.start()
        } catch {
            Log.session.error("listening could not open the microphone: \(String(describing: error), privacy: .public)")
            return await unavailable(.describing(error))
        }
        guard shouldListen else { return await capture.stop() }

        Log.session.info("continuous listening has the microphone")
        detector.reset()
        skipUntil = listened + configuration.settle
        setState(.listening)

        // The microphone is closed from here as soon as it shouldn't be open, even when it isn't producing anything to notice by.
        let clock = clock
        let poll = configuration.poll
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: poll)
                guard let self, !Task.isCancelled else { return }
                if !shouldListen {
                    await capture.stop()
                    return
                }
            }
        }
        let levels = Task { [weak self] in
            for await level in streams.levels {
                guard !Task.isCancelled else { return }
                self?.onLevel?(level)
            }
        }
        var failure: UserFacingError?
        do {
            for try await chunk in streams.chunks { hear(chunk) }
        } catch {
            failure = .describing(error)
        }
        watcher.cancel()
        levels.cancel()
        await capture.stop()
        Log.session.info("continuous listening let go of the microphone")

        // A stream that ended because Voxa became busy is the ordinary way out; one that ended by itself is a failure.
        if let failure, shouldListen { return await unavailable(failure) }
        if shouldListen {
            // The stream ended with nothing wrong and nothing asking it to: look again shortly rather than spin.
            await pause(configuration.poll)
        }
    }

    private func unavailable(_ error: UserFacingError) async {
        setState(.unavailable(error))
        await pause(configuration.retry)
    }

    // MARK: Hearing

    private func hear(_ chunk: AudioChunk) {
        listened += Double(chunk.samples.count) / AudioChunk.canonicalSampleRate
        guard listened >= skipUntil else { return }

        for event in detector.process(chunk) {
            switch event {
            case .speechStarted:
                lastActivity = listened
            case .discarded:
                break
            case .utterance(let utterance):
                lastActivity = listened
                enqueue(utterance.samples)
            }
        }
        stopIfIdle()
    }

    /// Switches itself off once nothing has been said for as long as Settings allows.
    private func stopIfIdle() {
        let configured = settings.current.listeningIdleMinutes
        let limit = configuration.idleSecondsOverride ?? Double(configured) * 60
        guard limit > 0, isOn, worker == nil, backlog.isEmpty, listened - lastActivity > limit else { return }
        let minutes = configuration.idleSecondsOverride == nil ? configured : max(1, Int((limit / 60).rounded(.up)))
        Log.session.info("continuous listening switched itself off after \(minutes) minutes of silence")
        setOn(false)
        onStop?(.idle(minutes: minutes))
    }

    private func enqueue(_ samples: [Float]) {
        backlog.append(samples)
        if backlog.count > configuration.backlog { backlog.removeFirst(backlog.count - configuration.backlog) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, !backlog.isEmpty {
            let next = backlog.removeFirst()
            await handle(next)
        }
        worker = nil
    }

    // MARK: Deciding

    /// Turns one utterance into text and, if it is a command, hands it over.
    private func handle(_ samples: [Float]) async {
        guard shouldListen else { return }
        let text = await transcribe(samples)
        // Time has passed: a key may have been pressed, or it may have been switched off.
        guard shouldListen, let text else { return }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCommand(command) else { return }
        if host?.submitCommand(command) == true { lastActivity = listened }
    }

    /// Whether what was heard is words to act on, and not a cough or a sigh the engine wrote down.
    private func isCommand(_ text: String) -> Bool {
        let core = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return core.count >= configuration.minimumCommandLength && !Self.fillers.contains(core)
    }

    /// Noises that speech engines write as words. Said on their own they are not commands.
    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhm", "uhh", "er", "erm", "err", "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "mmhm", "uhhuh", "ah", "ahh",
        "oh", "ohh", "eh", "huh",
    ]

    // MARK: Speech to text

    /// The text of an utterance, or nil when it could not be made in time. Runs on this Mac, like every recognizer here.
    private func transcribe(_ samples: [Float]) async -> String? {
        let snapshot = settings.current
        let recognizer = recognizers.recognizer(for: snapshot)
        let locale = snapshot.locale
        let audio = Self.chunks(of: samples)
        let timeout = configuration.transcriptionTimeout
        let clock = clock

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var latest = ""
                do {
                    for try await transcript in recognizer.transcribe(audio, locale: locale) { latest = transcript.text }
                } catch {
                    Log.session.notice("listening could not read an utterance: \(String(describing: error), privacy: .public)")
                    return nil
                }
                return latest
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    private static func chunks(of samples: [Float]) -> AsyncThrowingStream<AudioChunk, any Error> {
        AsyncThrowingStream { continuation in
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 1_600, samples.count)
                continuation.yield(
                    AudioChunk(samples: Array(samples[offset..<end]), startTime: Double(offset) / AudioChunk.canonicalSampleRate)
                )
                offset = end
            }
            continuation.finish()
        }
    }
}
