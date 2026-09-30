import AVFAudio
import Foundation
import VoxaAudio
import VoxaCore
import VoxaSpeech

// MARK: - vad

/// The samples of an audio file, at the canonical rate.
private func samples(of path: String) async throws -> [Float] {
    let capture = FileAudioCapture(url: URL(fileURLWithPath: path))
    let streams = try await capture.start()
    var samples: [Float] = []
    for try await chunk in streams.chunks { samples += chunk.samples }
    return samples
}

private func power(of samples: [Float]) -> Float {
    let mean = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count, 1))
    return 10 * log10(mean + 1e-12)
}

/// `samples` scaled to a mean power of `decibels`.
private func scaled(_ samples: [Float], to decibels: Float) -> [Float] {
    let current = power(of: samples)
    guard current > -100 else { return samples }
    let gain = pow(10, (decibels - current) / 20)
    return samples.map { $0 * gain }
}

/// Noise for testing: `white` (a hiss), `rumble` (a fan or a road), `hum` (a steady tone).
private func noise(_ kind: String, seconds: Double, decibels: Float) -> [Float] {
    let count = Int(seconds * AudioChunk.canonicalSampleRate)
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    func random() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
    }
    switch kind {
    case "white":
        return scaled((0..<count).map { _ in random() }, to: decibels)
    case "hum":
        return scaled((0..<count).map { Float(sin(2 * .pi * 180 * Double($0) / AudioChunk.canonicalSampleRate)) }, to: decibels)
    default:
        var previous: Float = 0
        return scaled((0..<count).map { _ in
            previous = 0.95 * previous + 0.05 * random()
            return previous
        }, to: decibels)
    }
}

/// Writes 16-bit mono PCM, so a segment can be listened to.
private func writeWAV(_ samples: [Float], to url: URL) throws {
    let rate = Int(AudioChunk.canonicalSampleRate)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
    for sample in samples { append(Int16(max(-1, min(1, sample)) * 32_767)) }
    try data.write(to: url)
}

/// The audio a command works on: the clip in the first argument with silence around it (and repeated, and with noise or another
/// recording mixed under it), as the options say.
private func composedStream(_ arguments: [String]) async throws -> [Float] {
    guard let path = arguments.first, !path.hasPrefix("--") else { fail("Missing audio file.\n\n\(usage)") }
    let lead = Double(option("--lead", in: arguments) ?? "2") ?? 2
    let trail = Double(option("--trail", in: arguments) ?? "2") ?? 2
    let repeats = max(1, Int(option("--repeat", in: arguments) ?? "1") ?? 1)
    let gap = Double(option("--gap", in: arguments) ?? "2") ?? 2
    let level = option("--level", in: arguments).flatMap(Float.init)

    var clip = try await samples(of: path)
    guard !clip.isEmpty else { fail("error: no audio in \(path)") }
    print("file: \(path)  \(String(format: "%.2f", Double(clip.count) / AudioChunk.canonicalSampleRate)) s  power \(String(format: "%.1f", power(of: clip))) dB")
    if let level { clip = scaled(clip, to: level) }

    let rate = AudioChunk.canonicalSampleRate
    var stream = [Float](repeating: 0, count: Int(lead * rate))
    for index in 0..<repeats {
        stream += clip
        stream += [Float](repeating: 0, count: Int((index == repeats - 1 ? trail : gap) * rate))
    }

    if let spec = option("--noise", in: arguments) {
        let parts = spec.split(separator: ":")
        let kind = String(parts.first ?? "rumble")
        let decibels = parts.count > 1 ? Float(parts[1]) ?? -40 : -40
        let room = noise(kind, seconds: Double(stream.count) / rate, decibels: decibels)
        for index in stream.indices { stream[index] += room[index] }
        print("noise: \(kind) at \(decibels) dB")
    }
    if let background = option("--background", in: arguments) {
        let decibels = option("--background-db", in: arguments).flatMap(Float.init) ?? -40
        var talk = try await samples(of: background)
        talk = scaled(talk, to: decibels)
        guard !talk.isEmpty else { fail("error: no audio in \(background)") }
        for index in stream.indices { stream[index] += talk[index % talk.count] }
        print("background speech: \(background) at \(decibels) dB")
    }
    return stream
}

/// Feeds `stream` to a detector in 100 ms pieces, as the microphone pipeline delivers it, and returns what it found. When `verbose`,
/// prints each event as it happens.
private func detectUtterances(in stream: [Float], verbose: Bool) -> [VoiceActivityDetector.Utterance] {
    var detector = VoiceActivityDetector()
    var found: [VoiceActivityDetector.Utterance] = []
    let rate = AudioChunk.canonicalSampleRate
    func show(_ events: [VoiceActivityDetector.Event], at seconds: Double) {
        for event in events {
            switch event {
            case .speechStarted(let time):
                if verbose { print(String(format: "  [%6.2f s] speech started (at %.2f s)", seconds, time)) }
            case .utterance(let utterance):
                found.append(utterance)
                if verbose {
                    let span = String(format: "%.2f–%.2f s", utterance.start, utterance.start + utterance.duration)
                    let detail = String(format: "%.2f s, voice %.2f s", utterance.duration, utterance.voice)
                    print(String(format: "  [%6.2f s] utterance ", seconds) + "\(span)  (\(detail))")
                }
            case .discarded(let duration):
                if verbose { print(String(format: "  [%6.2f s] discarded %.2f s (too little speech)", seconds, duration)) }
            }
        }
    }
    var fed = 0
    while fed < stream.count {
        let end = min(fed + 1_600, stream.count)
        show(detector.process(Array(stream[fed..<end])), at: Double(end) / rate)
        fed = end
    }
    show(detector.flush(), at: Double(stream.count) / rate)
    return found
}

func vad(_ arguments: [String]) async {
    do {
        let stream = try await composedStream(arguments)
        let found = detectUtterances(in: stream, verbose: true)
        print("\(found.count) utterance\(found.count == 1 ? "" : "s") in \(String(format: "%.1f", Double(stream.count) / AudioChunk.canonicalSampleRate)) s")

        if let directory = option("--save-dir", in: arguments) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (index, utterance) in found.enumerated() {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("utterance-\(index + 1).wav")
                try writeWAV(utterance.samples, to: url)
                print("saved \(url.path)")
            }
        }
    } catch {
        let described = UserFacingError.describing(error)
        fail("error: \(described.title)\n       \(described.detail)")
    }
}

// MARK: - handsfree

/// What continuous listening would do with a recording, using the real speech engine: the detector cuts it into utterances, each is
/// turned into text, and each that is words would be handed to Voxa as a command. Nothing is run; it prints what would be.
func handsFree(_ arguments: [String]) async {
    let engine = option("--engine", in: arguments) ?? "automatic"
    let locale = Locale(identifier: option("--locale", in: arguments) ?? AppSettings.systemLocaleIdentifier)
    do {
        let stream = try await composedStream(arguments)
        let recognizer = makeRecognizer(named: engine)
        print("engine: \(engine), locale: \(locale.identifier)")

        let found = detectUtterances(in: stream, verbose: false)
        var commands = 0
        for (index, utterance) in found.enumerated() {
            let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
                var offset = 0
                while offset < utterance.samples.count {
                    let end = min(offset + 1_600, utterance.samples.count)
                    let piece = Array(utterance.samples[offset..<end])
                    continuation.yield(AudioChunk(samples: piece, startTime: Double(offset) / AudioChunk.canonicalSampleRate))
                    offset = end
                }
                continuation.finish()
            }
            var text = ""
            let started = Date()
            for try await transcript in recognizer.transcribe(audio, locale: locale) { text = transcript.text }
            let took = Date().timeIntervalSince(started)
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCommand = command.count >= 2 && command.contains { $0.isLetter || $0.isNumber }
            if isCommand { commands += 1 }
            let span = String(format: "%.2f–%.2f s", utterance.start, utterance.start + utterance.duration)
            let verdict = isCommand ? "COMMAND" : "not a command (dropped)"
            print(String(format: "  #%d  ", index + 1) + span + String(format: "  heard in %.2f s: ", took) + "“\(text)”  →  \(verdict)")
        }
        print("\(found.count) utterance\(found.count == 1 ? "" : "s"), \(commands) command\(commands == 1 ? "" : "s")")
    } catch {
        let described = UserFacingError.describing(error)
        fail("error: \(described.title)\n       \(described.detail)")
    }
}
