import AVFAudio
import Testing
@testable import VoxaAudio
import VoxaCore
import VoxaTestSupport

@Suite("SpeechFormatConverter")
struct SpeechFormatConverterTests {
    @Test("audio already at 16 kHz mono passes through unchanged")
    func passthrough() throws {
        let samples = TestSignal.sine(sampleRate: 16_000, seconds: 0.25)
        let output = try SpeechFormatConverter().convert(TestSignal.buffer(channels: [samples], sampleRate: 16_000))
        #expect(output == samples)
    }

    @Test("48 kHz mono resamples to 16 kHz with the same tone and level", arguments: [48_000.0, 44_100.0, 24_000.0, 8_000.0])
    func resampling(sourceRate: Double) throws {
        let seconds = 0.5
        let input = TestSignal.sine(frequency: 440, sampleRate: sourceRate, seconds: seconds, amplitude: 0.5)
        let output = try SpeechFormatConverter().convert(TestSignal.buffer(channels: [input], sampleRate: sourceRate))

        // Length: within a few dozen samples of the ideal ratio (the filter holds back a few ms of look-ahead).
        #expect(abs(output.count - 8_000) < 100, "got \(output.count) samples")
        // Pitch: a 440 Hz tone crosses zero ~880 times per second.
        let crossings = TestSignal.zeroCrossings(output)
        #expect(abs(crossings - 440) < 12, "got \(crossings) zero crossings")
        // Level: the amplitude survives the anti-aliasing filter.
        let peak = output.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.56, "peak was \(peak)")
    }

    @Test("stereo is averaged to mono")
    func stereoDownmix() throws {
        let left = [Float](repeating: 0.6, count: 1_600)
        let right = [Float](repeating: 0.2, count: 1_600)
        let output = try SpeechFormatConverter().convert(TestSignal.buffer(channels: [left, right], sampleRate: 16_000))
        #expect(output.count == 1_600)
        #expect(output.allSatisfy { abs($0 - 0.4) < 0.0001 })
    }

    @Test("interleaved multi-channel buffers are downmixed too")
    func interleavedDownmix() throws {
        let left = [Float](repeating: 0.8, count: 800)
        let right = [Float](repeating: -0.4, count: 800)
        let buffer = TestSignal.buffer(channels: [left, right], sampleRate: 16_000, interleaved: true)
        let output = try SpeechFormatConverter().convert(buffer)
        #expect(output.count == 800)
        #expect(output.allSatisfy { abs($0 - 0.2) < 0.0001 })
    }

    @Test("many small buffers produce one continuous signal, with no clicks at the seams")
    func chunkedContinuity() throws {
        let sourceRate = 48_000.0
        let whole = TestSignal.sine(frequency: 440, sampleRate: sourceRate, seconds: 1, amplitude: 0.5)
        let converter = SpeechFormatConverter()

        var output: [Float] = []
        let block = 1_024
        var index = 0
        while index < whole.count {
            let end = min(index + block, whole.count)
            output += try converter.convert(TestSignal.buffer(channels: [Array(whole[index..<end])], sampleRate: sourceRate))
            index = end
        }

        #expect(abs(output.count - 16_000) < 150, "got \(output.count) samples")
        // The steepest slope of a 0.5-amplitude 440 Hz sine at 16 kHz is ~0.086 per sample; a seam glitch would
        // show up as a much bigger jump.
        let largestStep = zip(output, output.dropFirst()).map { abs($0.1 - $0.0) }.max() ?? 0
        #expect(largestStep < 0.12, "largest sample-to-sample step was \(largestStep)")
    }

    @Test("a mid-stream sample-rate change is handled")
    func rateChange() throws {
        let converter = SpeechFormatConverter()
        func buffer(rate: Double) -> AVAudioPCMBuffer {
            TestSignal.buffer(channels: [TestSignal.sine(sampleRate: rate, seconds: 0.1)], sampleRate: rate)
        }
        let first = try converter.convert(buffer(rate: 48_000))
        let second = try converter.convert(buffer(rate: 24_000))
        // A one-shot call holds back the filter's look-ahead (~15 ms), so allow a shortfall but not a wild count.
        #expect((1_200...1_700).contains(first.count), "got \(first.count)")
        #expect((1_200...1_700).contains(second.count), "got \(second.count)")
    }

    @Test("an empty buffer converts to nothing")
    func emptyBuffer() throws {
        let buffer = TestSignal.buffer(channels: [[]], sampleRate: 48_000)
        #expect(try SpeechFormatConverter().convert(buffer).isEmpty)
    }

    @Test("mono samples can be converted directly")
    func directMono() throws {
        let input = TestSignal.sine(sampleRate: 32_000, seconds: 0.5)
        let output = try SpeechFormatConverter().convert(monoSamples: input, sourceRate: 32_000)
        #expect(abs(output.count - 8_000) < 100)
    }
}
