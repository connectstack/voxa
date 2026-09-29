import Testing
@testable import VoxaAudio
import VoxaCore

@Suite("CapturePipeline")
struct CapturePipelineTests {
    private func collect(_ pipeline: CapturePipeline) async throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for try await chunk in pipeline.streams.chunks {
            chunks.append(chunk)
        }
        return chunks
    }

    @Test("chunks are delivered in order with running timestamps")
    func ordering() async throws {
        let pipeline = CapturePipeline()
        pipeline.emit([Float](repeating: 0.1, count: 1_600))
        pipeline.emit([Float](repeating: 0.2, count: 800))
        pipeline.finish()

        let chunks = try await collect(pipeline)
        #expect(chunks.count == 2)
        #expect(chunks[0].startTime == 0)
        #expect(chunks[1].startTime == 0.1)
        #expect(chunks[1].samples.first == 0.2)
    }

    @Test("finishing with an error delivers it after the buffered audio")
    func finishWithError() async {
        let pipeline = CapturePipeline()
        pipeline.emit([0.1, 0.2])
        pipeline.finish(throwing: AudioCaptureError.deviceLost)

        var received = 0
        do {
            for try await _ in pipeline.streams.chunks { received += 1 }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? AudioCaptureError == .deviceLost)
        }
        #expect(received == 1)
    }

    @Test("nothing is delivered after finish, and a second finish is ignored")
    func afterFinish() async throws {
        let pipeline = CapturePipeline()
        pipeline.finish()
        pipeline.emit([0.5])
        pipeline.finish(throwing: AudioCaptureError.deviceLost)
        #expect(try await collect(pipeline).isEmpty)
    }

    @Test("each chunk also produces a level, and the level stream ends with the capture")
    func levels() async {
        let pipeline = CapturePipeline()
        pipeline.emit([Float](repeating: 0.5, count: 1_600))
        pipeline.finish()

        var levels: [AudioLevel] = []
        for await level in pipeline.streams.levels { levels.append(level) }
        #expect(levels.count == 1)
        #expect((levels.first?.rms ?? 0) > 0.5)
    }
}
