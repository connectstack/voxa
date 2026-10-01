import Foundation
import Testing
@testable import VoxaAudio

@Suite("LevelStatistics and InputDevice")
struct LevelStatisticsTests {
    @Test("how long, how loud at the most and how loud on average, in decibels, for the log")
    func measures() {
        var heard = LevelStatistics()
        // A second of a 0.5 square wave, then a second of nothing.
        heard.add((0..<16_000).map { $0 % 2 == 0 ? 0.5 : -0.5 })
        heard.add([Float](repeating: 0, count: 16_000))
        #expect(abs(heard.seconds - 2) < 0.001)
        #expect(heard.peakDecibels == -6)
        #expect(heard.rmsDecibels == -9, "half the time at 0.5 is an rms of 0.35, which is -9 dBFS")
    }

    @Test("silence is -120, not a crash, and nothing heard has no length")
    func silence() {
        var heard = LevelStatistics()
        #expect(heard.seconds == 0)
        #expect(heard.peakDecibels == -120 && heard.rmsDecibels == -120)
        heard.add([0, 0, 0])
        #expect(heard.peakDecibels == -120 && heard.rmsDecibels == -120)
    }

    @Test("the default input device is read without opening it, and what is read makes sense")
    func inputDevice() {
        // A machine with no microphone (a build server) has none to read; otherwise it has a name and a rate, and a volume if it has one.
        guard let device = InputDevice.current() else { return }
        #expect(device.sampleRate >= 0)
        if let volume = device.volume { #expect((0...1).contains(volume)) }
    }
}
