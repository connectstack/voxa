import Foundation
import Observation
import VoxaAgent
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaPermissions
import VoxaSpeech

/// Runs one push-to-talk command from key press to recognized text, and drives the HUD and menu-bar state while doing so.
///
/// Flow: press → make sure permissions are granted → open the microphone → stream audio to the speech engine while the
/// HUD shows the live transcript → release → keep recording briefly (so the last syllable isn't clipped), stop the
/// microphone, wait for the final transcript → hand the command to the agent → show its reply.
///
/// While the agent works, the HUD follows it (thinking, acting, asking). A press during a confirmation records a spoken
/// yes or no instead of a new command; a press while the agent is working otherwise does nothing. Esc cancels the
/// command at any point.
///
/// Everything here runs on the main actor; the microphone and recognizers are the only things that hop off it. There is
/// at most one active run. Time is only ever consumed through the injected clock, so the tail, the accidental-tap
/// filter, the recording limit and the finalization watchdog are all deterministic in tests.
@MainActor
@Observable
public final class VoiceSessionController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Checking permissions and opening the microphone.
        case starting
        case listening
        /// The key is up; the last audio is being transcribed.
        case finalizing
        /// The run ended in an error that is still on screen.
        case failed
    }

    public struct Configuration: Sendable {
        /// Extra capture time after the key is released so the last syllable isn't clipped.
        public var releaseTail: Duration = .milliseconds(250)
        /// A press released sooner than this is an accidental tap and is dropped without a message.
        public var minimumHold: Duration = .milliseconds(300)
        /// How long to wait for the final transcript once the microphone has stopped.
        public var finalizationTimeout: Duration = .seconds(5)
        public var resultDisplay: Duration = .seconds(3)
        public var noticeDisplay: Duration = .milliseconds(2500)
        public var errorDisplay: Duration = .seconds(8)
        /// How long a reply stays up: a base time plus a little per word, so a longer answer can be read.
        public var replyBase: Duration = .seconds(4)
        public var replyPerWord: Duration = .milliseconds(350)
        public var replyMaximum: Duration = .seconds(20)

        public init() {}
    }

    /// What the agent is doing between the end of the recording and its reply.
    public enum AgentStage: Equatable, Sendable {
        case thinking
        case acting
    }

    public internal(set) var phase: Phase = .idle
    public internal(set) var agentStage: AgentStage?
    /// The most recent failure, kept for the menu until a new command starts.
    public internal(set) var lastError: UserFacingError?

    let capture: any AudioCapturing
    private let recognizers: any SpeechRecognizerProviding
    let permissions: any PermissionsProviding
    let hud: any HUDPresenting
    let hotkeys: any HotkeyService
    let settings: any SettingsProviding
    let clock: any Clock<Duration>
    let configuration: Configuration
    let openAppSettings: @MainActor () -> Void
    let openModelSettings: @MainActor () -> Void
    let agent: (any AgentRunning)?
    let confirmations: (any ConfirmationResponding)?
    let now: @Sendable () -> Date

    @ObservationIgnored var run: Run?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored var errorResetTask: Task<Void, Never>?
    /// Keeps Esc bound to "dismiss" while a finished command's result or error is still on screen.
    @ObservationIgnored var dismissWatcher: Task<Void, Never>?
    @ObservationIgnored var dismissDisarm: Task<Void, Never>?
    @ObservationIgnored var agentTask: Task<Void, Never>?
    @ObservationIgnored var agentCancelWatcher: Task<Void, Never>?
    /// Identifies the current agent command, so a late event or result from one that was cancelled is ignored.
    @ObservationIgnored var agentToken: UUID?

    public init(
        capture: any AudioCapturing,
        recognizers: any SpeechRecognizerProviding,
        permissions: any PermissionsProviding,
        hud: any HUDPresenting,
        hotkeys: any HotkeyService,
        settings: any SettingsProviding,
        clock: any Clock<Duration> = ContinuousClock(),
        configuration: Configuration = Configuration(),
        openAppSettings: @escaping @MainActor () -> Void = {},
        openModelSettings: @escaping @MainActor () -> Void = {},
        agent: (any AgentRunning)? = nil,
        confirmations: (any ConfirmationResponding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capture = capture
        self.recognizers = recognizers
        self.permissions = permissions
        self.hud = hud
        self.hotkeys = hotkeys
        self.settings = settings
        self.clock = clock
        self.configuration = configuration
        self.openAppSettings = openAppSettings
        self.openModelSettings = openModelSettings
        self.agent = agent
        self.confirmations = confirmations
        self.now = now
    }

    /// The coarse state shown by the menu-bar icon.
    public var status: AppStatus {
        if phase == .starting || phase == .listening { return .listening }
        if confirmations?.isAwaitingAnswer == true { return .confirming }
        if let agentStage { return agentStage == .acting ? .acting : .thinking }
        switch phase {
        case .idle: return .idle
        case .starting, .listening: return .listening
        case .finalizing: return .thinking
        case .failed: return .error
        }
    }

    // MARK: Lifecycle

    /// Starts reacting to the push-to-talk shortcut. Call once at launch.
    public func start() {
        guard eventTask == nil else { return }
        hud.onRecovery = { [weak self] action in self?.handleRecovery(action) }

        let events = hotkeys.pushToTalk
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .pressed: pressBegan()
                case .released: pressEnded()
                }
            }
        }
    }

    // MARK: Input

    /// The push-to-talk key went down.
    public func pressBegan() {
        if let run, !run.isFinished {
            Log.session.debug("press ignored: a command is already in progress")
            return
        }
        // While the agent works, a press is only meaningful as the answer to a confirmation.
        var kind = Run.Kind.command
        if agentTask != nil {
            guard confirmations?.isAwaitingAnswer == true else {
                Log.session.debug("press ignored: the agent is working")
                return
            }
            kind = .answer
        }
        errorResetTask?.cancel()
        disarmDismiss()

        let run = Run(kind: kind)
        self.run = run
        if kind == .command {
            lastError = nil
            hud.hotkeyHint = hotkeys.pushToTalkDescription
            hud.beginSession()
        }
        phase = .starting

        // The hold is measured from the key press, not from when the microphone finishes opening.
        run.minimumHoldTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: configuration.minimumHold)
            guard !Task.isCancelled else { return }
            run.minimumHoldElapsed = true
        }
        run.task = Task { [weak self] in await self?.perform(run) }
    }

    /// The push-to-talk key went up.
    public func pressEnded() {
        guard let run, !run.isFinished, !run.releaseRequested else { return }
        run.releaseRequested = true

        // A tap: answer right away instead of waiting for permissions or the microphone, which may take a moment.
        guard run.minimumHoldElapsed else {
            run.isCancelled = true
            run.task?.cancel()
            tapped(run)
            return
        }
        // A real hold that ends while still starting: `perform` notices the flag once the microphone is open.
        if phase == .listening {
            beginStopSequence(run)
        }
    }

    /// Does the slow first-use work (asking the system which speech engine can run) ahead of the first command, so the
    /// first press after launch isn't spent waiting on it. Call once at launch; safe to call again.
    public func prewarm() async {
        let snapshot = settings.current
        _ = await recognizers.recognizer(for: snapshot).requiredPermissions(locale: snapshot.locale)
    }

    /// The user pressed Esc: abort the running command, or dismiss a result or error that is still showing.
    public func cancel() {
        if agentTask != nil {
            Log.session.info("command cancelled by the user")
            cancelAgent()
            return
        }
        guard let run, !run.isFinished else {
            disarmDismiss()
            hud.hide(after: nil)
            return
        }
        Log.session.info("command cancelled by the user")
        run.isCancelled = true
        run.task?.cancel()
        finish(run)
        phase = .idle
        hud.hide(after: nil)
    }

    // MARK: The run

    private func perform(_ run: Run) async {
        let snapshot = settings.current
        let locale = snapshot.locale
        let recognizer = recognizers.recognizer(for: snapshot)

        // 1. Permissions. macOS may show system prompts here, so this can take a while.
        let engineNeeds = await recognizer.requiredPermissions(locale: locale)
        let required = [PermissionKind.microphone] + engineNeeds.sorted { $0.rawValue < $1.rawValue }
        let willPrompt = required.contains { permissions.status(of: $0) == .notDetermined }
        if let error = await permissions.ensureGranted(required) {
            return fail(run, with: error)
        }
        guard run.isActive else { return }
        if run.releaseRequested {
            // The key came up before there was anything to record: after a permission prompt that is expected, otherwise
            // it was a tap.
            return willPrompt ? announceReady(run) : tapped(run)
        }

        // 2. Open the microphone.
        let streams: AudioCaptureStreams
        do {
            streams = try await capture.start()
        } catch {
            return fail(run, with: .describing(error))
        }
        guard run.isActive else {
            await capture.stop()
            return
        }

        // 3. Listening. If the key is already up, skip the "Listening…" flash: this was a tap, or the user is done.
        phase = .listening
        if run.kind == .answer {
            hud.setAnswerStatus(.listening)
        } else {
            if !run.releaseRequested {
                hud.show(.listening)
            }
            armCancelKey(for: run)
        }
        armRecordingLimit(for: run, after: .seconds(snapshot.maxRecordingSeconds))
        let levelTask = Task { [weak self] in
            await self?.consume(levels: streams.levels, for: run)
        }
        if run.releaseRequested {
            beginStopSequence(run)
        }

        // 4. Transcribe until the recognizer finishes, which it does once the microphone has stopped.
        var latest = Transcript(text: "", isFinal: false)
        do {
            for try await transcript in recognizer.transcribe(streams.chunks, locale: locale) {
                guard run.isActive else { break }
                latest = transcript
                if run.kind == .command {
                    hud.setTranscript(transcript.text, isFinal: transcript.isFinal)
                }
            }
        } catch is CancellationError {
            // The finalization watchdog fired; the latest hypothesis stands.
        } catch {
            levelTask.cancel()
            return fail(run, with: .describing(error))
        }
        levelTask.cancel()
        guard run.isActive else { return }

        complete(run, transcript: latest.text)
    }

    private func consume(levels: AsyncStream<AudioLevel>, for run: Run) async {
        for await level in levels {
            guard run.isActive else { return }
            if run.kind == .command { hud.push(level: level) }
        }
    }

    // MARK: Stopping

    /// Called when the key is released or the recording limit is reached.
    private func beginStopSequence(_ run: Run) {
        guard run.isActive, run.stopTask == nil else { return }

        guard run.minimumHoldElapsed else {
            run.isCancelled = true
            run.task?.cancel()
            tapped(run)
            return
        }

        run.stopTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: configuration.releaseTail)
            guard !Task.isCancelled, run.isActive else { return }

            phase = .finalizing
            if run.kind == .command { hud.show(.transcribing) }
            await capture.stop()

            // Watchdog: if the recognizer never delivers a final transcript, go with what we have.
            try? await clock.sleep(for: configuration.finalizationTimeout)
            guard !Task.isCancelled, run.isActive else { return }
            Log.session.warning("recognizer did not finish in time; using the latest partial transcript")
            run.task?.cancel()
        }
    }

    private func armCancelKey(for run: Run) {
        let presses = hotkeys.cancelKeyPresses()
        run.cancelWatcher = Task { [weak self] in
            for await _ in presses {
                self?.cancel()
            }
        }
    }

    private func armRecordingLimit(for run: Run, after limit: Duration) {
        run.limitTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: limit)
            guard !Task.isCancelled, run.isActive, phase == .listening else { return }
            Log.session.info("recording limit reached; stopping")
            run.minimumHoldElapsed = true
            beginStopSequence(run)
        }
    }
}

// MARK: - Run state

/// The mutable state of one push-to-talk command. A class so the tasks it spawns and the controller share one copy.
@MainActor
final class Run {
    /// A command is recorded to be carried out; an answer is recorded to answer a confirmation.
    enum Kind { case command, answer }

    let kind: Kind
    var task: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var limitTask: Task<Void, Never>?
    var minimumHoldTask: Task<Void, Never>?
    var cancelWatcher: Task<Void, Never>?

    var releaseRequested = false
    var minimumHoldElapsed = false
    var isCancelled = false
    var isFinished = false

    var isActive: Bool { !isFinished && !isCancelled }

    init(kind: Kind) {
        self.kind = kind
    }

    func cancelHelpers() {
        stopTask?.cancel()
        limitTask?.cancel()
        minimumHoldTask?.cancel()
        cancelWatcher?.cancel()
    }
}
