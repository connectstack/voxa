import Testing
@testable import VoxaAudio
import VoxaCore

@Suite("LevelMeter")
struct LevelMeterTests {
    private let rate = AudioChunk.canonicalSampleRate

    @Test("silence reads as zero")
    func silence() {
        var meter = LevelMeter()
        let level = meter.process([Float](repeating: 0, count: 1_600), sampleRate: rate)
        #expect(level.rms == 0)
        #expect(level.peak == 0)
    }

    @Test("full-scale audio drives the meter to the top")
    func fullScale() {
        var meter = LevelMeter()
        let level = meter.process([Float](repeating: 1, count: 3_200), sampleRate: rate)
        #expect(level.rms > 0.95)
        #expect(level.peak == 1)
    }

    @Test("the mapping is linear in decibels between the floor and 0 dBFS")
    func decibelMapping() {
        let meter = LevelMeter(floorDecibels: -50)
        #expect(abs(meter.normalized(linear: 1) - 1) < 0.001)
        #expect(abs(meter.normalized(linear: 0.1) - 0.6) < 0.001)   // -20 dBFS
        #expect(abs(meter.normalized(linear: 0.01) - 0.2) < 0.001)  // -40 dBFS
        #expect(meter.normalized(linear: 0.001) == 0)               // -60 dBFS is below the floor
    }

    @Test("invalid amplitudes never produce NaN or out-of-range values", arguments: [Float.nan, -1, 0, .infinity, 5])
    func invalid(amplitude: Float) {
        let meter = LevelMeter()
        let value = meter.normalized(linear: amplitude)
        #expect(value >= 0 && value <= 1)
    }

    @Test("the meter rises quickly and falls gradually")
    func attackAndRelease() {
        var meter = LevelMeter()
        let block = 320 // 20 ms
        var last: Float = 0
        for _ in 0..<10 {
            last = meter.process([Float](repeating: 0.5, count: block), sampleRate: rate).rms
        }
        let peakLevel = last
        #expect(peakLevel > 0.7)

        var falling: [Float] = []
        for _ in 0..<10 {
            falling.append(meter.process([Float](repeating: 0, count: block), sampleRate: rate).rms)
        }
        #expect(falling.first! < peakLevel)                      // starts falling immediately
        #expect(zip(falling, falling.dropFirst()).allSatisfy { $0 >= $1 })  // monotonic decay
        #expect(falling.last! > 0.01)                            // ...but not instantly
    }

    @Test("reset returns to silence")
    func reset() {
        var meter = LevelMeter()
        _ = meter.process([Float](repeating: 0.8, count: 3_200), sampleRate: rate)
        meter.reset()
        #expect(meter.process([Float](repeating: 0, count: 320), sampleRate: rate).rms == 0)
    }

    @Test("empty input is harmless")
    func emptyInput() {
        var meter = LevelMeter()
        #expect(meter.process([], sampleRate: rate).peak == 0)
        #expect(meter.process([0.5], sampleRate: 0).peak == 0)
    }
}
