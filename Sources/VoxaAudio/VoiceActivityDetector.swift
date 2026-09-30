import Accelerate
import Foundation
import VoxaCore

/// Finds where speech starts and stops in a running stream of microphone audio, so an always-open microphone can be cut into
/// utterances.
///
/// It listens in 20 ms frames. A frame counts as speech when it is clearly louder than the room (a noise floor that follows the
/// quietest tenth of the last few seconds, so a fan or a distant television is absorbed) and doesn't look like a click, a hiss
/// or a hum (its zero-crossing rate, which is low for a voice, high for broadband noise and lowest for a hum). An utterance
/// starts once enough recent frames are speech, keeps a little audio from before it (so the first syllable isn't clipped), and
/// ends after a stretch of quiet, keeping a little of that too.
///
/// This decides *when someone is talking*, not *whether it is meant for Voxa*: it is fooled by a television as easily as by a
/// person, which is why the wake phrase, and not this, is what lets anything through.
public struct VoiceActivityDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Samples in a frame: 20 ms at the canonical 16 kHz.
        public var frameSamples = 320
        /// How far above the noise floor a frame must be for speech to *start*, and to *carry on*.
        public var onsetMarginDecibels: Float = 10
        public var sustainMarginDecibels: Float = 5
        /// Nothing quieter than this is speech, however quiet the room is.
        public var silenceFloorDecibels: Float = -55
        /// The noise floor is never taken to be above this: a room louder than that can't be told from speech.
        public var maximumFloorDecibels: Float = -32
        /// Nothing is reported in this long after listening begins: the room has not been heard yet, and a fan that was already
        /// on would be taken for speech. (Speech that began just before the end of it is still kept whole.)
        public var warmUp: TimeInterval = 1
        /// A voice crosses zero between these fractions of the samples; a click or a hiss is above, a hum below.
        public var minimumZeroCrossingRate: Float = 0.01
        public var maximumZeroCrossingRate: Float = 0.35
        /// Speech frames needed among the last `onsetWindow` to start an utterance (120 ms of the last 200 ms).
        public var onsetFrames = 6
        public var onsetWindow = 10
        /// Quiet that ends an utterance. Long enough to leave a pause between two words, short enough to feel prompt.
        public var endSilence: TimeInterval = 0.8
        /// Audio kept from before the speech began, and from the quiet after it.
        public var preRoll: TimeInterval = 0.3
        public var tail: TimeInterval = 0.2
        /// Less than this much voice is a cough or a knock, not a command.
        public var minimumVoice: TimeInterval = 0.3
        public var minimumUtterance: TimeInterval = 0.4
        /// An utterance is cut here, and the next one starts.
        public var maximumUtterance: TimeInterval = 30
        /// How much recent history the noise floor looks at, and how quickly it follows a room that gets louder, and quieter. While
        /// someone is talking it is slower to rise, because what it is hearing is not the room.
        public var floorWindow: TimeInterval = 6
        public var floorRise: TimeInterval = 1.5
        public var speechFloorRise: TimeInterval = 4
        public var floorFall: TimeInterval = 0.2

        public init() {}
    }

    /// One stretch of speech, with the audio around it.
    public struct Utterance: Sendable, Equatable {
        public var samples: [Float]
        /// Seconds from the start of the stream to the first sample.
        public var start: TimeInterval
        public var duration: TimeInterval
        /// How much of it was voice (the rest is the audio kept before and after).
        public var voice: TimeInterval
    }

    public enum Event: Sendable, Equatable {
        /// Speech has begun (reported a little after it did, once it is clear it wasn't a click).
        case speechStarted(at: TimeInterval)
        case utterance(Utterance)
        /// Something that sounded like speech for a moment and wasn't enough of it.
        case discarded(duration: TimeInterval)
    }

    public static let sampleRate = AudioChunk.canonicalSampleRate

    public var configuration: Configuration

    // MARK: State

    /// Samples that don't yet make a whole frame.
    private var carry: [Float] = []
    private var framesSeen = 0
    /// The frame energies of the last `floorWindow`, for the noise floor.
    private var history: [Float] = []
    private var floorDecibels: Float = -120
    /// Whether each of the last `onsetWindow` frames was speech.
    private var recentSpeech: [Bool] = []
    /// The first frame of the run of speech being looked at (nil once a stretch of it has been all quiet), and how many of its
    /// frames were speech. An utterance is announced a little after its run begins, once it has gone on too long to be a click,
    /// and it starts where the run did.
    private var runStart: Int?
    private var runVoiceFrames = 0
    /// The last frames' samples, for the audio before speech begins.
    private var ring: [[Float]] = []
    private var isInSpeech = false
    private var frames: [[Float]] = []
    private var voiceFrames = 0
    private var quietRun = 0
    private var utteranceStartFrame = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Drops whatever was in progress (a half-heard utterance, the audio kept from before it) and starts listening afresh. What
    /// the room sounds like is kept: a break in the audio is no reason to forget it.
    public mutating func reset() {
        carry.removeAll()
        recentSpeech.removeAll()
        runStart = nil
        ring.removeAll()
        isInSpeech = false
        frames.removeAll()
        voiceFrames = 0
        quietRun = 0
    }

    /// Feeds the next audio. Returns what it found, in order (usually nothing).
    public mutating func process(_ chunk: AudioChunk) -> [Event] {
        process(chunk.samples)
    }

    public mutating func process(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        carry.append(contentsOf: samples)
        let size = configuration.frameSamples
        var offset = 0
        while carry.count - offset >= size {
            let frame = Array(carry[offset..<offset + size])
            offset += size
            handle(frame, into: &events)
        }
        carry.removeFirst(offset)
        return events
    }

    /// The stream has ended: finishes an utterance that was still going.
    public mutating func flush() -> [Event] {
        var events: [Event] = []
        if isInSpeech { finish(into: &events) }
        carry.removeAll()
        return events
    }

    // MARK: Frames

    private var frameDuration: TimeInterval { Double(configuration.frameSamples) / Self.sampleRate }

    private func seconds(_ frames: Int) -> TimeInterval { Double(frames) * frameDuration }

    private func framesIn(_ seconds: TimeInterval) -> Int { Int((seconds / frameDuration).rounded(.up)) }

    private mutating func handle(_ frame: [Float], into events: inout [Event]) {
        let energy = Self.decibels(of: frame)
        let crossings = Self.zeroCrossingRate(of: frame)
        let isWarmingUp = seconds(framesSeen) < configuration.warmUp
        updateFloor(with: energy, learningQuickly: isWarmingUp)
        let floor = floorDecibels

        let margin = isInSpeech ? configuration.sustainMarginDecibels : configuration.onsetMarginDecibels
        let loud = energy > max(floor + margin, configuration.silenceFloorDecibels)
        // Once an utterance is under way only loudness matters: the tail of a word can be breathy, and a hiss between two words
        // shouldn't cut one utterance in two. To *start*, it must also sound like a voice.
        let isVoice = crossings >= configuration.minimumZeroCrossingRate && crossings <= configuration.maximumZeroCrossingRate
        let isSpeech = isInSpeech ? loud : (loud && isVoice)

        let index = framesSeen
        framesSeen += 1
        recentSpeech.append(isSpeech)
        if recentSpeech.count > configuration.onsetWindow { recentSpeech.removeFirst() }
        if isSpeech {
            if runStart == nil {
                runStart = index
                runVoiceFrames = 0
            }
            runVoiceFrames += 1
        } else if !recentSpeech.contains(true) {
            runStart = nil
        }
        // Enough to reach back past the warm-up, or the window an utterance is decided in, to before the speech began.
        let keep = framesIn(configuration.preRoll) + max(configuration.onsetWindow, framesIn(configuration.warmUp)) + 2
        ring.append(frame)
        if ring.count > keep { ring.removeFirst(ring.count - keep) }

        if isInSpeech {
            frames.append(frame)
            if isSpeech {
                voiceFrames += 1
                quietRun = 0
            } else {
                quietRun += 1
            }
            if seconds(quietRun) >= configuration.endSilence || seconds(frames.count) >= configuration.maximumUtterance {
                finish(into: &events)
            }
        } else if !isWarmingUp, recentSpeech.filter({ $0 }).count >= configuration.onsetFrames {
            begin(into: &events)
        }
    }

    /// Starts an utterance from the run of speech that made it start, and the audio before that.
    private mutating func begin(into events: inout [Event]) {
        // The run began no earlier than the oldest frame still kept.
        let first = max(runStart ?? framesSeen - recentSpeech.count, framesSeen - ring.count)
        let firstInRing = ring.count - (framesSeen - first)
        frames = Array(ring[max(0, firstInRing - framesIn(configuration.preRoll))...])
        voiceFrames = runVoiceFrames
        quietRun = recentSpeech.reversed().prefix { !$0 }.count
        isInSpeech = true
        utteranceStartFrame = framesSeen - frames.count
        events.append(.speechStarted(at: seconds(first)))
    }

    /// Ends the utterance: trims the quiet at its end down to a short tail, and keeps it if there was enough voice in it.
    private mutating func finish(into events: inout [Event]) {
        let tailFrames = framesIn(configuration.tail)
        let trimmed = max(0, quietRun - tailFrames)
        if trimmed > 0, trimmed <= frames.count { frames.removeLast(trimmed) }
        let voice = seconds(voiceFrames)
        let duration = seconds(frames.count)
        if voice >= configuration.minimumVoice, duration >= configuration.minimumUtterance {
            events.append(
                .utterance(
                    Utterance(
                        samples: frames.flatMap { $0 },
                        start: seconds(utteranceStartFrame),
                        duration: duration,
                        voice: voice
                    )
                )
            )
        } else {
            events.append(.discarded(duration: duration))
        }
        isInSpeech = false
        frames.removeAll(keepingCapacity: true)
        voiceFrames = 0
        quietRun = 0
        recentSpeech.removeAll()
        runStart = nil
    }

    // MARK: The noise floor

    /// The floor follows the quietest tenth of the last few seconds, so speech (which is never quiet for long) doesn't raise it
    /// and a room that gets louder or quieter is followed.
    private mutating func updateFloor(with energy: Float, learningQuickly: Bool) {
        history.append(energy)
        let capacity = Int(configuration.floorWindow / frameDuration)
        if history.count > capacity { history.removeFirst(history.count - capacity) }

        let sorted = history.sorted()
        let target = min(sorted[sorted.count / 10], configuration.maximumFloorDecibels)
        if learningQuickly {
            floorDecibels = target
            return
        }
        let time = target < floorDecibels ? configuration.floorFall : (isInSpeech ? configuration.speechFloorRise : configuration.floorRise)
        let alpha = Float(1 - exp(-frameDuration / time))
        floorDecibels += alpha * (target - floorDecibels)
    }

    // MARK: Measuring

    /// Mean power of `samples` in decibels relative to full scale. A frame with a sample that isn't a number reads as silence: a
    /// NaN that got into the noise floor would leave the detector deaf for good.
    static func decibels(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var power: Float = 0
        samples.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &power, vDSP_Length($0.count)) }
        let decibels = 10 * log10(power + 1e-12)
        return decibels.isFinite ? decibels : -120
    }

    /// The fraction of neighbouring samples that lie on opposite sides of zero.
    static func zeroCrossingRate(of samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        return Float(crossings) / Float(samples.count - 1)
    }
}
