import Accelerate
import Foundation
import VoxaCore

/// Turns raw samples into the smooth, perceptually scaled level the HUD draws.
///
/// The mapping is linear in decibels between `floorDecibels` (silence, 0) and 0 dBFS (1): speech at a normal
/// distance lands around 0.4–0.7, and a quiet room stays near zero. The body is smoothed with separate attack
/// and release time constants so the meter rises quickly and falls gracefully.
public struct LevelMeter: Sendable {
    public var floorDecibels: Float
    /// Time constant (seconds) used when the level rises.
    public var attack: TimeInterval
    /// Time constant (seconds) used when the level falls.
    public var release: TimeInterval

    private var smoothed: Float = 0

    public init(floorDecibels: Float = -50, attack: TimeInterval = 0.03, release: TimeInterval = 0.15) {
        self.floorDecibels = floorDecibels
        self.attack = attack
        self.release = release
    }

    public mutating func reset() {
        smoothed = 0
    }

    /// Processes one block. `sampleRate` is only used to scale the smoothing by the block's duration.
    public mutating func process(_ samples: [Float], sampleRate: Double) -> AudioLevel {
        guard !samples.isEmpty, sampleRate > 0 else { return AudioLevel(rms: smoothed, peak: 0) }

        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            vDSP_rmsqv(buffer.baseAddress!, 1, &rms, vDSP_Length(buffer.count))
            vDSP_maxmgv(buffer.baseAddress!, 1, &peak, vDSP_Length(buffer.count))
        }

        let target = normalized(linear: rms)
        let duration = Double(samples.count) / sampleRate
        let tau = target > smoothed ? attack : release
        let alpha = tau > 0 ? Float(1 - exp(-duration / tau)) : 1
        smoothed += alpha * (target - smoothed)

        return AudioLevel(rms: smoothed, peak: normalized(linear: peak))
    }

    /// Maps a linear amplitude (0…1) onto the meter's 0…1 decibel scale.
    public func normalized(linear amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }
}
