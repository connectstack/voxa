import Foundation
import VoxaCore

/// Sounds for tests to play into things that listen. Nothing here is random or read from a file: the same test always hears the
/// same thing.
public enum TestSound {
    public static let rate = AudioChunk.canonicalSampleRate

    public static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// `samples`, scaled so its mean power is `decibels` (relative to full scale).
    public static func scaled(_ samples: [Float], to decibels: Float) -> [Float] {
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count, 1))
        guard power > 0 else { return samples }
        let gain = (pow(10, decibels / 10) / power).squareRoot()
        return samples.map { $0 * gain }
    }

    /// Something with a voice's shape: a low fundamental and its overtones, swelling and dipping about four times a second like
    /// syllables, but never falling silent inside itself.
    public static func voice(_ seconds: Double, decibels: Float = -25, fundamental: Double = 140) -> [Float] {
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / rate
            let syllables = 0.7 + 0.3 * sin(2 * .pi * 4 * time)
            var value = 0.0
            for harmonic in 1...8 { value += sin(2 * .pi * fundamental * Double(harmonic) * time) / Double(harmonic) }
            samples[index] = Float(value * syllables)
        }
        return scaled(samples, to: decibels)
    }

    /// Uniform noise between -1 and 1, from a fixed seed.
    public static func whiteNoise(_ seconds: Double, decibels: Float, seed: UInt64 = 0x2545_F491_4F6C_DD1D) -> [Float] {
        var state = seed
        let samples = (0..<Int(seconds * rate)).map { _ -> Float in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
        }
        return scaled(samples, to: decibels)
    }

    /// Low rumble: noise with nothing above a couple of hundred hertz, the sound of a fan or a road.
    public static func rumble(_ seconds: Double, decibels: Float) -> [Float] {
        var previous: Float = 0
        let samples = whiteNoise(seconds, decibels: 0).map { value -> Float in
            previous = 0.95 * previous + 0.05 * value
            return previous
        }
        return scaled(samples, to: decibels)
    }

    /// A steady tone, such as mains hum.
    public static func tone(_ seconds: Double, hertz: Double, decibels: Float) -> [Float] {
        let samples = (0..<Int(seconds * rate)).map { Float(sin(2 * .pi * hertz * Double($0) / rate)) }
        return scaled(samples, to: decibels)
    }

    /// Adds `other` to `base` from `offset` seconds in.
    public static func mixed(_ base: [Float], with other: [Float], at offset: Double = 0) -> [Float] {
        var result = base
        let start = Int(offset * rate)
        for (index, value) in other.enumerated() where start + index < result.count { result[start + index] += value }
        return result
    }
}
