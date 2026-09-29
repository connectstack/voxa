import AVFAudio
import Testing
@testable import VoxaCore

@Suite("AudioChunk")
struct AudioChunkTests {
    @Test("duration follows sample count and rate")
    func duration() {
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 8_000), startTime: 0)
        #expect(chunk.duration == 0.5)
        #expect(chunk.sampleRate == 16_000)
    }

    @Test("an empty chunk has no duration and no PCM buffer")
    func empty() {
        let chunk = AudioChunk(samples: [], startTime: 1)
        #expect(chunk.isEmpty)
        #expect(chunk.duration == 0)
        #expect(chunk.makePCMBuffer() == nil)
    }

    @Test("the PCM buffer carries the same samples in mono Float32")
    func pcmBufferRoundTrip() throws {
        let samples: [Float] = (0..<320).map { Float(sin(Double($0) / 10)) }
        let buffer = try #require(AudioChunk(samples: samples, startTime: 0).makePCMBuffer())

        #expect(buffer.format.channelCount == 1)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(Int(buffer.frameLength) == samples.count)

        let copied = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: samples.count))
        #expect(copied == samples)
    }
}
