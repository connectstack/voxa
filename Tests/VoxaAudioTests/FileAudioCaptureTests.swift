import Foundation
import Testing
@testable import VoxaAudio
import VoxaCore
import VoxaTestSupport

@Suite("FileAudioCapture")
struct FileAudioCaptureTests {
    @Test("a file is delivered as canonical 16 kHz chunks covering its whole duration")
    func playsFile() async throws {
        let url = try TestSignal.writeWAV(TestSignal.sine(frequency: 300, sampleRate: 44_100, seconds: 1), sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = FileAudioCapture(url: url)
        let streams = try await capture.start()

        var chunks: [AudioChunk] = []
        for try await chunk in streams.chunks { chunks.append(chunk) }

        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16_000) < 200, "got \(total) samples")
        #expect(chunks.allSatisfy { $0.sampleRate == 16_000 })
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.startTime < $1.startTime })

        let crossings = TestSignal.zeroCrossings(chunks.flatMap(\.samples))
        #expect(abs(crossings - 600) < 12, "300 Hz for one second crosses zero ~600 times, got \(crossings)")
    }

    @Test("levels are reported while playing")
    func reportsLevels() async throws {
        let url = try TestSignal.writeWAV(TestSignal.sine(sampleRate: 16_000, seconds: 0.5, amplitude: 0.5), sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let streams = try await FileAudioCapture(url: url).start()
        var maxLevel: Float = 0
        for await level in streams.levels { maxLevel = max(maxLevel, level.rms) }
        #expect(maxLevel > 0.3)
    }

    @Test("an unreadable file fails with a user-facing error")
    func unreadableFile() async {
        let capture = FileAudioCapture(url: URL(fileURLWithPath: "/nonexistent/voxa.wav"))
        do {
            _ = try await capture.start()
            Issue.record("expected start() to throw")
        } catch let error as AudioCaptureError {
            guard case .fileUnreadable = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(!error.userFacing.title.isEmpty)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("stopping ends the streams")
    func stopEndsStreams() async throws {
        let url = try TestSignal.writeWAV(TestSignal.sine(sampleRate: 16_000, seconds: 5), sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = FileAudioCapture(url: url, realTime: true)
        let streams = try await capture.start()
        var iterator = streams.chunks.makeAsyncIterator()
        _ = try await iterator.next()
        await capture.stop()

        var drained = 0
        while try await iterator.next() != nil { drained += 1 }
        #expect(drained < 10, "the 5 s file should have been cut short")
    }
}
