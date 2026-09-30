import Foundation
import Testing
@testable import VoxaAudio
import VoxaCore
import VoxaTestSupport

/// Feeds `samples` to a detector in pieces of `chunk` samples and collects everything it reports, with the number of seconds of
/// audio that had been fed when each event came out.
private func listen(
    to samples: [Float],
    chunk: Int = 320,
    with configuration: VoiceActivityDetector.Configuration = .init(),
    flush: Bool = false
) -> [(event: VoiceActivityDetector.Event, heardAt: Double)] {
    var detector = VoiceActivityDetector(configuration: configuration)
    var found: [(VoiceActivityDetector.Event, Double)] = []
    var fed = 0
    while fed < samples.count {
        let end = min(fed + chunk, samples.count)
        for event in detector.process(Array(samples[fed..<end])) { found.append((event, Double(end) / TestSound.rate)) }
        fed = end
    }
    if flush { for event in detector.flush() { found.append((event, Double(samples.count) / TestSound.rate)) } }
    return found
}

private func utterances(in events: [(event: VoiceActivityDetector.Event, heardAt: Double)]) -> [VoiceActivityDetector.Utterance] {
    events.compactMap {
        if case .utterance(let utterance) = $0.event { utterance } else { nil }
    }
}

private func starts(in events: [(event: VoiceActivityDetector.Event, heardAt: Double)]) -> [Double] {
    events.compactMap {
        if case .speechStarted(let time) = $0.event { time } else { nil }
    }
}

private func discards(in events: [(event: VoiceActivityDetector.Event, heardAt: Double)]) -> Int {
    events.filter {
        if case .discarded = $0.event { true } else { false }
    }.count
}

private func seconds(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2)))
}

private func describe(_ events: [(event: VoiceActivityDetector.Event, heardAt: Double)]) -> String {
    let lines = events.map { entry -> String in
        switch entry.event {
        case .speechStarted(let time): "started \(seconds(time))"
        case .utterance(let utterance):
            "utterance \(seconds(utterance.start))+\(seconds(utterance.duration)) voice \(seconds(utterance.voice))"
        case .discarded(let duration): "discarded \(seconds(duration))"
        }
    }
    return lines.joined(separator: ", ")
}

private func describe(_ events: [VoiceActivityDetector.Event]) -> String {
    describe(events.map { (event: $0, heardAt: 0) })
}

@Suite("VoiceActivityDetector")
struct VoiceActivityDetectorTests {
    // MARK: One utterance

    @Test("silence, however long, reports nothing")
    func silence() {
        #expect(listen(to: TestSound.silence(20)).isEmpty)
    }

    @Test("one spoken phrase between silences is reported once, with a little before and after it")
    func onePhrase() throws {
        let stream = TestSound.silence(1) + TestSound.voice(1.5) + TestSound.silence(2)
        let events = listen(to: stream)

        let found = try #require(utterances(in: events).first, "\(describe(events))")
        #expect(utterances(in: events).count == 1, "\(describe(events))")
        #expect(discards(in: events) == 0)
        // Speech began at 1.0 s; 0.3 s of the quiet before it is kept.
        #expect(abs(found.start - 0.7) < 0.05, "\(found.start)")
        // 0.3 s before, 1.5 s of voice, 0.2 s after.
        #expect(abs(found.duration - 2.0) < 0.1, "\(found.duration)")
        #expect(abs(found.voice - 1.5) < 0.15, "\(found.voice)")
        #expect(found.samples.count == Int((found.duration * TestSound.rate).rounded()), "\(found.samples.count)")
    }

    @Test("the start is announced soon after speech begins, and the utterance only once the speaker has stopped")
    func timing() throws {
        let stream = TestSound.silence(1) + TestSound.voice(1.5) + TestSound.silence(2)
        let events = listen(to: stream)

        let announced = try #require(events.first { if case .speechStarted = $0.event { true } else { false } }, "\(describe(events))")
        #expect(abs(announced.heardAt - 1.12) < 0.06, "\(announced.heardAt)")
        if case .speechStarted(let time) = announced.event { #expect(abs(time - 1.0) < 0.05, "\(time)") }

        let delivered = try #require(events.first { if case .utterance = $0.event { true } else { false } }, "\(describe(events))")
        // Voice stops at 2.5 s and the utterance is delivered after 0.8 s of quiet.
        #expect(abs(delivered.heardAt - 3.3) < 0.06, "\(delivered.heardAt)")
    }

    @Test("the audio kept before the speech is quiet, and the speech itself is in the samples")
    func preRollIsBeforeTheSpeech() throws {
        let voice = TestSound.voice(1)
        let stream = TestSound.silence(1) + voice + TestSound.silence(2)
        let found = try #require(utterances(in: listen(to: stream)).first)

        let preRoll = Int(0.25 * TestSound.rate)
        #expect(found.samples.prefix(preRoll).allSatisfy { $0 == 0 })
        let heard = found.samples.dropFirst(Int(0.3 * TestSound.rate))
        #expect(Array(heard.prefix(3_000)) == Array(voice.prefix(3_000)))
    }

    @Test("how the audio is cut into chunks makes no difference", arguments: [1, 7, 100, 319, 320, 321, 1_600, 4_000, 1_000_000])
    func chunkSizeIndependence(chunk: Int) throws {
        let stream = TestSound.silence(1) + TestSound.voice(1.2) + TestSound.silence(1.5) + TestSound.voice(0.8) + TestSound.silence(2)
        let reference = utterances(in: listen(to: stream, chunk: 320))
        let found = utterances(in: listen(to: stream, chunk: chunk))

        #expect(reference.count == 2, "\(reference.map(\.duration))")
        #expect(found == reference, "chunk \(chunk): \(found.map(\.duration)) instead of \(reference.map(\.duration))")
    }

    @Test("nothing starts in the first moments of listening, while the room is still being heard")
    func warmUp() {
        let events = listen(to: TestSound.voice(0.9) + TestSound.silence(1.5))
        #expect(starts(in: events).allSatisfy { $0 >= 1 }, "\(describe(events))")
    }

    @Test("speech that begins just after the room has been heard is found, whole")
    func speechAfterWarmUp() throws {
        let stream = TestSound.silence(1.05) + TestSound.voice(1) + TestSound.silence(1.5)
        let found = try #require(utterances(in: listen(to: stream)).first)
        #expect(found.start > 0.7 && found.start < 0.9, "\(found.start)")
        #expect(found.duration > 1.4 && found.duration < 1.6, "\(found.duration)")
    }

    @Test("speech that carries on past the warm-up is announced once it is over, but kept whole")
    func speechAcrossTheWarmUp() throws {
        let events = listen(to: TestSound.silence(0.6) + TestSound.voice(1.4) + TestSound.silence(1.5))
        let announced = try #require(events.first { if case .speechStarted = $0.event { true } else { false } }, "\(describe(events))")
        #expect(announced.heardAt >= 1, "\(describe(events))")
        let found = try #require(utterances(in: events).first, "\(describe(events))")
        // 0.3 s before the speech at 0.6 s, the speech to 2.0 s, and 0.2 s after.
        #expect(abs(found.start - 0.3) < 0.05 && abs(found.duration - 1.9) < 0.1, "\(describe(events))")
    }

    // MARK: Pauses

    @Test("a pause between two words does not split the utterance")
    func shortPause() {
        let stream = TestSound.silence(1) + TestSound.voice(0.6) + TestSound.silence(0.5) + TestSound.voice(0.6) + TestSound.silence(2)
        let found = utterances(in: listen(to: stream))

        #expect(found.count == 1, "\(found.map(\.duration))")
        // 0.3 before, 0.6 + 0.5 + 0.6, 0.2 after.
        #expect(abs((found.first?.duration ?? 0) - 2.2) < 0.1, "\(found.first?.duration ?? 0)")
    }

    @Test("a longer pause ends one utterance and the next words are another")
    func longPause() {
        let stream = TestSound.silence(1) + TestSound.voice(0.6) + TestSound.silence(1.2) + TestSound.voice(0.6) + TestSound.silence(1.5)
        let found = utterances(in: listen(to: stream))

        #expect(found.count == 2, "\(found.map(\.duration))")
        #expect(found.allSatisfy { abs($0.duration - 1.1) < 0.1 }, "\(found.map(\.duration))")
        if found.count == 2 { #expect(found[1].start > found[0].start + found[0].duration) }
    }

    @Test("the end-of-speech quiet can be made longer")
    func configurableEnd() {
        var configuration = VoiceActivityDetector.Configuration()
        configuration.endSilence = 1.5
        let stream = TestSound.silence(1) + TestSound.voice(0.6) + TestSound.silence(1.2) + TestSound.voice(0.6) + TestSound.silence(2.5)
        #expect(utterances(in: listen(to: stream, with: configuration)).count == 1)
    }

    // MARK: What is not speech

    @Test("a knock or a click is not speech")
    func clicks() {
        var stream = TestSound.silence(1)
        for _ in 0..<3 {
            stream += TestSound.whiteNoise(0.005, decibels: -6) + TestSound.silence(0.1)
        }
        stream += TestSound.silence(2)
        #expect(listen(to: stream).isEmpty)
    }

    @Test("a cough-length burst of voice starts something and then is thrown away, not reported")
    func cough() {
        let events = listen(to: TestSound.silence(1) + TestSound.voice(0.15) + TestSound.silence(2))
        #expect(utterances(in: events).isEmpty, "\(describe(events))")
        #expect(discards(in: events) == 1, "\(describe(events))")
    }

    @Test("a sudden hiss is not speech")
    func hiss() {
        let events = listen(to: TestSound.silence(1) + TestSound.whiteNoise(2, decibels: -25) + TestSound.silence(2))
        #expect(events.isEmpty, "\(describe(events))")
    }

    @Test("very quiet sound is not speech in a silent room")
    func belowTheFloor() {
        let events = listen(to: TestSound.silence(1) + TestSound.voice(2, decibels: -70) + TestSound.silence(2))
        #expect(events.isEmpty, "\(describe(events))")
    }

    @Test("quiet speech in a quiet room is heard")
    func quietSpeech() {
        let events = listen(to: TestSound.silence(1) + TestSound.voice(1.5, decibels: -42) + TestSound.silence(2))
        #expect(utterances(in: events).count == 1, "\(describe(events))")
    }

    // MARK: The room

    @Test("a steady rumble is not speech, and speech over it is heard once")
    func rumbleAndSpeech() throws {
        let room = TestSound.rumble(9, decibels: -42)
        let stream = TestSound.mixed(room, with: TestSound.voice(1.5, decibels: -26), at: 4)
        let events = listen(to: stream)

        let found = try #require(utterances(in: events).first, "\(describe(events))")
        #expect(utterances(in: events).count == 1, "\(describe(events))")
        #expect(abs(found.start - 3.7) < 0.15, "\(found.start)")
        #expect(abs(found.voice - 1.5) < 0.3, "\(found.voice)")
    }

    @Test("a rumble that is there from the first moment never triggers")
    func steadyRumble() {
        let events = listen(to: TestSound.rumble(40, decibels: -38))
        #expect(events.isEmpty, "\(describe(events))")
    }

    @Test("a room that has been heard is not forgotten by a reset")
    func resetKeepsTheRoom() {
        var detector = VoiceActivityDetector()
        _ = detector.process(TestSound.rumble(15, decibels: -38))
        detector.reset()
        let events = detector.process(TestSound.rumble(15, decibels: -38)) + detector.flush()
        #expect(events.isEmpty, "\(describe(events))")
    }

    @Test("a hum that switches on mid-stream is taken for the room, not one endless utterance")
    func humIsAbsorbed() {
        let stream = TestSound.silence(1) + TestSound.tone(45, hertz: 180, decibels: -40)
        let events = listen(to: stream)

        // It may be taken for speech at first, but once it has gone on and on the room has "learnt" it, so it ends and does not
        // start again.
        let found = utterances(in: events)
        #expect(found.count == 1, "\(describe(events))")
        #expect((found.first?.duration ?? 100) < 25, "\(found.first?.duration ?? 100)")
        #expect(starts(in: events).count == 1, "\(describe(events))")
    }

    @Test("a mains hum below a voice's range is never speech")
    func lowHum() {
        #expect(listen(to: TestSound.silence(1) + TestSound.tone(3, hertz: 50, decibels: -30) + TestSound.silence(2)).isEmpty)
    }

    @Test("in a loud room speech has to be clearly louder than the room, and is heard when it is")
    func speechOverAFan() {
        // A fan at -34 dB from the start.
        let fan = TestSound.rumble(20, decibels: -34)
        func heard(_ speech: Float) -> Int {
            utterances(in: listen(to: TestSound.mixed(fan, with: TestSound.voice(1.2, decibels: speech), at: 12))).count
        }
        #expect(heard(-40) == 0, "speech 6 dB under a fan is not heard")
        #expect(heard(-18) == 1, "speech 16 dB over a fan is")
    }

    @Test("a room that gets louder is followed: speech that was clear is no longer once a fan has come on")
    func floorRises() {
        let speech = TestSound.voice(1.2, decibels: -38)
        // In a quiet room (from 0 s to 10 s) it is heard; with a fan that came on at 10 s, over the next few seconds, it is not.
        let quiet = TestSound.mixed(TestSound.silence(20), with: speech, at: 4)
        #expect(utterances(in: listen(to: quiet)).count == 1)

        let fanComesOn = TestSound.mixed(TestSound.silence(10) + TestSound.rumble(20, decibels: -34), with: speech, at: 26)
        let events = listen(to: fanComesOn)
        #expect(utterances(in: events).filter { $0.start > 20 }.isEmpty, "\(describe(events))")
    }

    // MARK: Limits

    @Test("a very long run of speech is cut at the limit and carries on as the next utterance")
    func maximumLength() {
        var configuration = VoiceActivityDetector.Configuration()
        configuration.maximumUtterance = 3
        var stream = TestSound.silence(1)
        for _ in 0..<8 { stream += TestSound.voice(0.8) + TestSound.silence(0.2) }
        stream += TestSound.silence(2)

        let found = utterances(in: listen(to: stream, with: configuration))
        #expect(found.count >= 2, "\(found.map(\.duration))")
        #expect(found.allSatisfy { $0.duration <= 3.05 }, "\(found.map(\.duration))")
        #expect(found.first.map { $0.duration >= 2.9 } == true, "\(found.map(\.duration))")
    }

    @Test("flush delivers what was being said when the stream ended")
    func flushDeliversTheEnd() throws {
        let stream = TestSound.silence(1) + TestSound.voice(1)
        let without = listen(to: stream)
        #expect(utterances(in: without).isEmpty)

        let with = listen(to: stream, flush: true)
        let found = try #require(utterances(in: with).first, "\(describe(with))")
        #expect(found.duration > 1.2 && found.duration < 1.4, "\(found.duration)")
    }

    @Test("flush after silence reports nothing, and does not report the same utterance twice")
    func flushIsQuiet() {
        #expect(listen(to: TestSound.silence(2), flush: true).isEmpty)
        let done = listen(to: TestSound.silence(1) + TestSound.voice(1) + TestSound.silence(2), flush: true)
        #expect(utterances(in: done).count == 1, "\(describe(done))")
    }

    @Test("reset forgets an utterance in progress and starts listening afresh")
    func reset() {
        var detector = VoiceActivityDetector()
        _ = detector.process(TestSound.silence(1) + TestSound.voice(1))
        detector.reset()
        #expect(detector.flush().isEmpty)
        let events = detector.process(TestSound.silence(1) + TestSound.voice(1) + TestSound.silence(2))
        #expect(events.contains { if case .utterance = $0 { true } else { false } }, "\(describe(events))")
    }

    // MARK: Odd input

    @Test("no samples, one sample and partial frames are harmless")
    func oddInput() {
        var detector = VoiceActivityDetector()
        #expect(detector.process([]).isEmpty)
        #expect(detector.process([0.5]).isEmpty)
        #expect(detector.process([Float](repeating: 0, count: 318)).isEmpty)
        #expect(detector.flush().isEmpty)
    }

    @Test("non-finite samples do not break it")
    func nonFinite() {
        var detector = VoiceActivityDetector()
        var samples = TestSound.silence(1)
        samples[100] = .nan
        samples[200] = .infinity
        samples[300] = -.infinity
        _ = detector.process(samples)
        let events = detector.process(TestSound.voice(1) + TestSound.silence(2))
        #expect(events.contains { if case .utterance = $0 { true } else { false } }, "\(describe(events))")
    }

    @Test("a chunk from the microphone pipeline is accepted as it is")
    func acceptsChunks() {
        var detector = VoiceActivityDetector()
        let voice = TestSound.silence(1) + TestSound.voice(1) + TestSound.silence(2)
        var events: [VoiceActivityDetector.Event] = []
        var start = 0
        while start < voice.count {
            let end = min(start + 1_600, voice.count)
            events += detector.process(AudioChunk(samples: Array(voice[start..<end]), startTime: Double(start) / TestSound.rate))
            start = end
        }
        #expect(events.contains { if case .utterance = $0 { true } else { false } }, "\(describe(events))")
    }
}
