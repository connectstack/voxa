import AVFAudio
import AVFoundation
import Foundation
import VoxaCore

/// Captures the default input device with `AVAudioEngine`.
///
/// Design notes:
/// - A fresh engine is created per capture, so a device change between commands can never leave stale state behind.
/// - The tap is installed with `format: nil`, i.e. the hardware's own format, and each buffer is converted to the
///   canonical 16 kHz mono format on the tap thread. That keeps working when the hardware format changes.
/// - macOS delivers *silence* (no error) when microphone access is denied, so authorization is checked up front.
/// - A route change (AirPods switching to the hands-free profile, a USB mic being unplugged) posts
///   `AVAudioEngineConfigurationChange` and stops the engine; we reinstall the tap and restart it so the utterance
///   survives, and only fail the capture if the restart itself fails.
public actor MicrophoneCapture: AudioCapturing {
    private var engine: AVAudioEngine?
    private var pipeline: CapturePipeline?
    private var configurationObserver: (any NSObjectProtocol)?

    private let tapBufferSize: AVAudioFrameCount
    private let authorizationStatus: @Sendable () -> PermissionStatus

    /// - Parameters:
    ///   - tapBufferSize: Requested frames per tap callback (the system may deliver a different size).
    ///   - authorizationStatus: Injectable so tests can exercise the denied paths without touching TCC.
    public init(
        tapBufferSize: AVAudioFrameCount = 1024,
        authorizationStatus: @escaping @Sendable () -> PermissionStatus = {
            PermissionStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    ) {
        self.tapBufferSize = tapBufferSize
        self.authorizationStatus = authorizationStatus
    }

    public func start() async throws -> AudioCaptureStreams {
        if engine != nil {
            Log.audio.warning("start() called while a capture is running; restarting it")
            tearDown()
        }

        let status = authorizationStatus()
        guard status.isGranted else { throw AudioCaptureError.microphoneNotAuthorized(status) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let pipeline = CapturePipeline()
        installTap(on: input, feeding: pipeline)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            pipeline.finish()
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.pipeline = pipeline
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }

        Log.audio.info(
            "capture started (\(Int(hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) channel(s))"
        )
        return pipeline.streams
    }

    public func stop() async {
        tearDown()
    }

    // MARK: Internals

    /// The tap block runs on an audio thread, so it must not inherit this actor's isolation. Marking it `@Sendable`
    /// makes it nonisolated (`AVAudioNodeTapBlock` itself carries no such annotation).
    private func installTap(on input: AVAudioInputNode, feeding pipeline: CapturePipeline) {
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { @Sendable buffer, _ in
            pipeline.handle(buffer)
        }
    }

    private func handleConfigurationChange() {
        guard let engine, let pipeline else { return }
        Log.audio.info("audio configuration changed; restarting the engine")
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        installTap(on: input, feeding: pipeline)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.audio.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
            pipeline.finish(throwing: AudioCaptureError.deviceLost)
            tearDown()
        }
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pipeline?.finish()
        engine = nil
        pipeline = nil
    }
}
