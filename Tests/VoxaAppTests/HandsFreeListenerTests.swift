import Foundation
import Testing
@testable import VoxaApp
import VoxaAudio
import VoxaCore
import VoxaPermissions
import VoxaSpeech
import VoxaTestSupport

/// The app, as far as the listener can tell: whether it is busy, and what it was asked to do.
@MainActor
final class FakeHandsFreeHost: HandsFreeHost {
    var availability: HandsFreeAvailability = .ready
    /// Whether a command is taken. When it is, Voxa becomes busy, as the real one does the moment the agent starts, unless
    /// `becomesBusy` is off.
    var accepts = true
    var becomesBusy = true
    private(set) var submitted: [String] = []

    var handsFreeAvailability: HandsFreeAvailability { availability }

    func submitCommand(_ command: String) -> Bool {
        guard accepts else { return false }
        submitted.append(command)
        if becomesBusy { availability = .working }
        return true
    }
}

/// What the recognizer will say for each utterance it is given, in order, and how much audio each was.
final class TranscriptQueue: SpeechRecognizerProviding, SpeechRecognizer, @unchecked Sendable {
    enum Answer: Sendable {
        case says(String)
        case fails
        case hangs
    }

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var heard: [Int] = []
    private var isHeld = false
    var permissions: Set<PermissionKind> = []

    /// Holds every answer back, as a slow recognizer would, until `release()`.
    func hold() { lock.withLock { isHeld = true } }
    func release() { lock.withLock { isHeld = false } }

    /// What it will say next, and the answer for every utterance after that.
    func queue(_ next: Answer...) {
        lock.withLock { answers.append(contentsOf: next) }
    }

    /// The number of samples in each utterance it was given.
    var samplesHeard: [Int] { lock.withLock { heard } }
    var callCount: Int { lock.withLock { heard.count } }

    func recognizer(for settings: AppSettings) -> any SpeechRecognizer { self }
    func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { permissions }
    func prepare(locale: Locale) async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples = 0
                do { for try await chunk in audio { samples += chunk.samples.count } } catch {}
                let answer: Answer = lock.withLock {
                    heard.append(samples)
                    return answers.isEmpty ? .says("") : answers.removeFirst()
                }
                while lock.withLock({ isHeld }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                switch answer {
                case .says(let text):
                    continuation.yield(Transcript(text: text, isFinal: true))
                    continuation.finish()
                case .fails:
                    continuation.finish(throwing: SpeechError.recognitionFailed("scripted"))
                case .hangs:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A listener wired to fakes, and the choreography a test needs: audio played into the microphone, and a clock that moves on.
@MainActor
final class HandsFreeHarness {
    let capture = FakeAudioCapture()
    let host = FakeHandsFreeHost()
    let permissions = FakePermissions()
    let settings: FakeSettings
    let clock = ManualClock()
    let transcripts = TranscriptQueue()
    let listener: HandsFreeListener
    private(set) var states: [HandsFreeState] = []
    private(set) var stops: [HandsFreeStopReason] = []
    private(set) var levels: [AudioLevel] = []

    /// - Parameter on: whether continuous listening is switched on as soon as the listener starts.
    init(on: Bool = true, idleMinutes: Int = 10, configuration: HandsFreeListener.Configuration = .init(), start: Bool = true) {
        settings = FakeSettings(
            AppSettings(speechEngine: .appleAutomatic, localeIdentifier: "en_US", listeningIdleMinutes: idleMinutes)
        )
        listener = HandsFreeListener(
            capture: capture,
            recognizers: transcripts,
            permissions: permissions,
            settings: settings,
            host: host,
            clock: clock,
            configuration: configuration
        )
        // Weak: the listener's tasks can outlive the test that made them.
        listener.onStateChange = { [weak self] in self?.states.append($0) }
        listener.onStop = { [weak self] in self?.stops.append($0) }
        listener.onLevel = { [weak self] in self?.levels.append($0) }
        if start { listener.start() }
        if on { listener.setOn(true) }
    }

    var isCapturing: Bool {
        get async { await capture.isCapturing }
    }

    func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
        await VoxaTestSupport.waitUntil(timeout: timeout, condition)
    }

    /// Waits for the microphone to be open, then lets the detector learn the room.
    func listenAndSettle() async -> Bool {
        guard await waitUntil({ await capture.isCapturing }), await waitUntil({ listener.state == .listening }) else { return false }
        await play(TestSound.silence(1.5))
        return true
    }

    /// Plays `samples` into the microphone in the 100 ms pieces the real one delivers.
    func play(_ samples: [Float]) async {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_600, samples.count)
            await capture.emit(Array(samples[offset..<end]))
            offset = end
            if offset % 16_000 == 0 { await Task.yield() }
        }
    }

    /// Someone speaks for a second and a bit, and stops.
    func speak(_ seconds: Double = 1.2) async {
        await play(TestSound.voice(seconds) + TestSound.silence(1.2))
    }

    /// Moves the clock on until `condition` holds (the listener's timers are armed by tasks of its own).
    func advanceClock(by step: Duration = .milliseconds(200), until condition: @MainActor () async -> Bool) async -> Bool {
        await waitUntil {
            clock.advance(by: step)
            return await condition()
        }
    }
}

@MainActor
@Suite("HandsFreeListener")
struct HandsFreeListenerTests {
    // MARK: Whether it listens

    @Test("until it is switched on the microphone is never opened")
    func off() async throws {
        let harness = HandsFreeHarness(on: false)
        try await Task.sleep(for: .milliseconds(100))
        harness.clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.capture.startCount == 0)
        #expect(harness.listener.state == .off && !harness.listener.isOn)
    }

    @Test("switched on with Voxa idle, the microphone opens and it listens")
    func on() async {
        let harness = HandsFreeHarness()
        #expect(harness.listener.isOn)
        #expect(harness.listener.state == .starting, "the bar can show the microphone as live the moment it is clicked")
        #expect(await harness.listenAndSettle())
        #expect(await harness.capture.startCount == 1)
        #expect(harness.listener.state == .listening)
    }

    @Test("switching it on later opens it, and switching it off closes it at once")
    func switching() async {
        let harness = HandsFreeHarness(on: false)
        harness.clock.advance(by: .milliseconds(200))
        #expect(await harness.capture.startCount == 0)

        harness.listener.setOn(true)
        #expect(await harness.advanceClock { harness.listener.state == .listening })
        #expect(await harness.isCapturing)

        harness.listener.setOn(false)
        #expect(harness.listener.state == .off && !harness.listener.isOn)
        #expect(await harness.advanceClock { await !harness.isCapturing })
    }

    @Test("every change of state is reported, in order")
    func reportsStates() async {
        let harness = HandsFreeHarness()
        #expect(await harness.listenAndSettle())
        harness.listener.setOn(false)
        #expect(harness.states == [.starting, .listening, .off])
    }

    @Test("the loudness of the microphone is passed on while it is open")
    func levels() async {
        let harness = HandsFreeHarness()
        #expect(await harness.listenAndSettle())
        await harness.capture.emit(level: AudioLevel(rms: 0.4, peak: 0.6))
        #expect(await harness.waitUntil { harness.levels.contains(AudioLevel(rms: 0.4, peak: 0.6)) })
    }

    @Test("it asks for the microphone and speech recognition before it listens")
    func asksForPermissions() async {
        let harness = HandsFreeHarness(on: false)
        harness.transcripts.permissions = [.speechRecognition]
        harness.permissions.statuses = [.microphone: .notDetermined, .speechRecognition: .notDetermined]
        harness.listener.setOn(true)
        #expect(await harness.advanceClock { await harness.capture.startCount == 1 })
        #expect(harness.permissions.requested == [.microphone, .speechRecognition])
    }

    @Test("without permission it says why, does not open the microphone, and tries again")
    func denied() async {
        let harness = HandsFreeHarness()
        harness.permissions.statuses = [.microphone: .denied]
        #expect(await harness.waitUntil { if case .unavailable = harness.listener.state { true } else { false } })
        #expect(await harness.capture.startCount == 0)
        #expect(harness.listener.isOn, "it is still switched on: the bar keeps showing the microphone as wanted")

        // The person grants it in System Settings; the next try finds it.
        harness.permissions.statuses = [.microphone: .granted]
        #expect(await harness.advanceClock(by: .seconds(3)) { harness.listener.state == .listening })
        #expect(await harness.capture.startCount == 1)
    }

    @Test("a microphone that can't be opened is reported and tried again")
    func microphoneFails() async {
        let harness = HandsFreeHarness(on: false)
        await harness.capture.setStartError(AudioCaptureError.noInputDevice)
        harness.listener.setOn(true)
        #expect(await harness.advanceClock { if case .unavailable = harness.listener.state { true } else { false } })

        await harness.capture.setStartError(nil)
        #expect(await harness.advanceClock(by: .seconds(3)) { harness.listener.state == .listening })
    }

    @Test("a microphone that stops by itself is treated as a failure, not silence")
    func streamFails() async {
        let harness = HandsFreeHarness()
        #expect(await harness.listenAndSettle())
        await harness.capture.fail(with: AudioCaptureError.deviceLost)
        #expect(await harness.waitUntil { if case .unavailable = harness.listener.state { true } else { false } })
        #expect(await harness.advanceClock(by: .seconds(3)) { harness.listener.state == .listening })
        #expect(await harness.capture.startCount == 2)
    }

    // MARK: Commands

    @Test("what is said is a command: no wake phrase, no key")
    func commandRuns() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("Open Safari."))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["Open Safari."] })
    }

    @Test("words that look like a wake phrase are just words")
    func noSpecialPhrase() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("hey voxa open safari"))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["hey voxa open safari"] })
    }

    @Test("it keeps listening: one command after another, each spoken once Voxa is quiet again")
    func continuous() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("open Safari"), .says("what time is it"))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["open Safari"] })

        // The command runs and Voxa answers: the microphone is closed meanwhile.
        #expect(await harness.advanceClock { harness.listener.state == .paused(.working) })
        harness.host.availability = .ready
        #expect(await harness.advanceClock { await harness.capture.startCount == 2 })
        #expect(await harness.waitUntil { harness.listener.state == .listening })

        await harness.play(TestSound.silence(0.6))
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["open Safari", "what time is it"] })
    }

    @Test("several utterances in a row, with Voxa free between them, are all commands")
    func severalInARow() async {
        let harness = HandsFreeHarness()
        harness.host.becomesBusy = false
        harness.transcripts.queue(.says("open Safari"), .says("open Notes"), .says("open Mail"))
        #expect(await harness.listenAndSettle())
        for _ in 0..<3 { await harness.speak(0.9) }
        #expect(await harness.waitUntil { harness.host.submitted == ["open Safari", "open Notes", "open Mail"] })
    }

    @Test("what isn't words is not a command: nothing, a cough, a sigh, punctuation", arguments: [
        "", "   ", "uh", "Um...", "Hmm.", "uh-huh", "...", "?!", "a", "ok", "Oh",
    ])
    func notWords(transcript: String) async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says(transcript))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.host.submitted.isEmpty)
    }

    @Test("what the recognizer is given is the utterance, with a little either side of it")
    func audioGiven() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("nothing to see"))
        #expect(await harness.listenAndSettle())
        await harness.speak(1.2)
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })
        let seconds = Double(harness.transcripts.samplesHeard[0]) / 16_000
        #expect(seconds > 1.5 && seconds < 2.0, "\(seconds)")
    }

    // MARK: Voxa being busy

    @Test("while a command is being carried out the microphone is closed, and it opens again once Voxa is quiet")
    func busyClosesTheMicrophone() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("open safari"))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted.count == 1 })

        // The host is now working: the watcher closes the microphone and the listener says why.
        #expect(await harness.advanceClock { harness.listener.state == .paused(.working) })
        #expect(await harness.waitUntil({ await !harness.isCapturing }))
        #expect(harness.listener.isOn, "it is still on: it only waits")

        // Voxa speaks its reply, then is done; only after a quiet moment does it listen again.
        harness.host.availability = .speaking
        harness.clock.advance(by: .milliseconds(400))
        #expect(await harness.capture.startCount == 1)
        harness.host.availability = .ready
        #expect(await harness.advanceClock { harness.listener.state == .listening })
        #expect(await harness.capture.startCount == 2)
    }

    @Test("Voxa's own voice is not heard: it stays deaf until a moment after it stops speaking")
    func quietAfterSpeaking() async {
        let harness = HandsFreeHarness()
        #expect(await harness.listenAndSettle())
        harness.host.availability = .speaking
        #expect(await harness.advanceClock { harness.listener.state == .paused(.speaking) })

        harness.host.availability = .ready
        // Three polls is not enough; the reply's last words may still be in the room.
        for _ in 0..<3 { harness.clock.advance(by: .milliseconds(200)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await harness.capture.startCount == 1)
        #expect(await harness.advanceClock { await harness.capture.startCount == 2 })
    }

    @Test("the shortcut takes the microphone: listening lets go of it and does not act on what was half heard")
    func pushToTalkWins() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("open safari"))
        harness.transcripts.hold()
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })

        // The key goes down while the utterance is still being read, and the reading then finishes.
        harness.host.availability = .pushToTalk
        harness.transcripts.release()
        #expect(await harness.advanceClock { harness.listener.state == .paused(.pushToTalk) })
        #expect(await harness.waitUntil({ await !harness.isCapturing }))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.host.submitted.isEmpty)
    }

    @Test("a command that can't be taken (Voxa got busy meanwhile) is dropped, and listening goes on")
    func refusedCommand() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.says("open Safari"), .says("open Notes"))
        harness.host.accepts = false
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })

        harness.host.accepts = true
        harness.host.becomesBusy = false
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["open Notes"] })
    }

    // MARK: Switching itself off

    @Test("after as long a silence as Settings allows it switches itself off, and says why")
    func idleSwitchesItOff() async {
        let harness = HandsFreeHarness(idleMinutes: 1)
        #expect(await harness.listenAndSettle())
        await harness.play(TestSound.silence(70))
        #expect(await harness.waitUntil { !harness.listener.isOn })
        #expect(harness.listener.state == .off)
        #expect(harness.stops == [.idle(minutes: 1)])
        #expect(await harness.advanceClock { await !harness.isCapturing })
    }

    @Test("a voice starts the silence over, even when what it says is not a command")
    func speechKeepsItOn() async {
        let harness = HandsFreeHarness(idleMinutes: 1)
        harness.transcripts.queue(.says("uh"), .says("uh"))
        #expect(await harness.listenAndSettle())
        // 40 s of quiet, a voice, 40 s more, a voice: 80 s in all, but never a minute of silence.
        await harness.play(TestSound.silence(40))
        await harness.speak()
        await harness.play(TestSound.silence(40))
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 2 })
        #expect(harness.listener.isOn)
        #expect(harness.stops.isEmpty)
        #expect(harness.host.submitted.isEmpty, "it was only a noise, so nothing was run")
    }

    @Test("zero minutes means it never switches itself off")
    func neverSwitchesOff() async {
        let harness = HandsFreeHarness(idleMinutes: 0)
        #expect(await harness.listenAndSettle())
        await harness.play(TestSound.silence(400))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.listener.isOn && harness.listener.state == .listening)
        #expect(harness.stops.isEmpty)
    }

    // MARK: Trouble

    @Test("an utterance the recognizer fails on is dropped and listening goes on")
    func recognizerFails() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.fails, .says("open safari"))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })
        await harness.speak()
        #expect(await harness.waitUntil { harness.host.submitted == ["open safari"] })
    }

    @Test("a recognizer that never answers is given up on after the timeout")
    func recognizerHangs() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.hangs, .says("open safari"))
        #expect(await harness.listenAndSettle())
        await harness.speak()
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })
        await harness.speak()
        #expect(await harness.advanceClock(by: .seconds(3)) { harness.transcripts.callCount == 2 })
        #expect(await harness.waitUntil { harness.host.submitted == ["open safari"] })
    }

    @Test("a room that never goes quiet does not build a queue: only the newest utterances are read")
    func backlogIsBounded() async {
        let harness = HandsFreeHarness()
        harness.transcripts.queue(.hangs)
        #expect(await harness.listenAndSettle())
        for _ in 0..<6 { await harness.speak(0.8) }
        #expect(await harness.waitUntil { harness.transcripts.callCount == 1 })
        // The first is stuck; of the five that came after, only the newest two are kept.
        #expect(await harness.advanceClock(by: .seconds(2)) { harness.transcripts.callCount == 3 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.transcripts.callCount == 3)
    }

    @Test("stopping closes the microphone and switches it off")
    func stopping() async {
        let harness = HandsFreeHarness()
        #expect(await harness.listenAndSettle())
        await harness.listener.stop()
        #expect(harness.listener.state == .off && !harness.listener.isOn)
        #expect(await !harness.isCapturing)
    }
}
