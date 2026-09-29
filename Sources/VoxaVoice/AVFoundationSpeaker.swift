import AVFoundation
import Foundation
import VoxaCore

/// Speaks with the voices macOS ships, through `AVSpeechSynthesizer`: on this Mac, free, and with no network.
@MainActor
public final class AVFoundationSpeaker: SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: String, options: SpeechOptions) {
        let prepared = SpokenText.prepare(text)
        stop()
        guard !prepared.isEmpty else { return }
        synthesizer.speak(Self.utterance(prepared, options: options))
    }

    public func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
    }

    public func voices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map(Self.info)
    }

    // MARK: Building

    static func utterance(_ text: String, options: SpeechOptions) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: options)
        let range = AppSettings.speechRateRange
        let rate = min(max(options.rate, range.lowerBound), range.upperBound)
        utterance.rate = Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        return utterance
    }

    static func voice(for options: SpeechOptions) -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let chosen = VoiceCatalog.choose(from: installed.map(info), preferred: options.voiceIdentifier, language: options.language)
        if let chosen, let voice = AVSpeechSynthesisVoice(identifier: chosen.id) { return voice }
        // Nothing matches the language: the system's own default voice, which is what nil means.
        return options.language.flatMap { AVSpeechSynthesisVoice(language: VoiceCatalog.normalize($0)) }
    }

    static func info(_ voice: AVSpeechSynthesisVoice) -> VoiceInfo {
        let quality: VoiceInfo.Quality =
            switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
        return VoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
    }

    // MARK: Rendering

    /// Renders `text` to audio samples without playing it, using the same voice choice. Used to prove a voice really produces
    /// sound (in tests and diagnostics) on a machine with no one listening.
    public static func render(_ text: String, options: SpeechOptions = SpeechOptions()) async -> (samples: [Float], sampleRate: Double) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = utterance(text, options: options)
        return await withCheckedContinuation { continuation in
            let collector = BufferCollector(continuation)
            synthesizer.write(utterance) { buffer in
                collector.receive(buffer)
            }
            // Keeps the synthesizer alive until the audio has all arrived.
            collector.hold(synthesizer)
        }
    }
}

/// Gathers the buffers `AVSpeechSynthesizer.write` delivers, on whatever queue it uses, and finishes when it says it is done.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 0.0
    private var continuation: CheckedContinuation<(samples: [Float], sampleRate: Double), Never>?
    private var retained: AVSpeechSynthesizer?

    init(_ continuation: CheckedContinuation<(samples: [Float], sampleRate: Double), Never>) {
        self.continuation = continuation
    }

    func hold(_ synthesizer: AVSpeechSynthesizer) {
        lock.lock()
        // Already finished (a very short utterance): nothing to keep alive.
        if continuation != nil { retained = synthesizer }
        lock.unlock()
    }

    func receive(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            // A buffer with no frames is how the synthesizer says it is finished.
            continuation?.resume(returning: (samples, sampleRate))
            continuation = nil
            retained = nil
            return
        }
        sampleRate = pcm.format.sampleRate
        let count = Int(pcm.frameLength)
        if let floats = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: floats[0], count: count))
        } else if let ints = pcm.int16ChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: ints[0], count: count).map { Float($0) / Float(Int16.max) })
        }
    }
}
