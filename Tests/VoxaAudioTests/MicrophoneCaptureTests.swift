import Testing
@testable import VoxaAudio
import VoxaCore

/// Only the paths that never touch audio hardware: authorization gating and idempotent stop.
@Suite("MicrophoneCapture")
struct MicrophoneCaptureTests {
    @Test("capture refuses to start without microphone access", arguments: [
        PermissionStatus.denied, .notDetermined, .restricted,
    ])
    func refusesWithoutAuthorization(status: PermissionStatus) async {
        let capture = MicrophoneCapture(authorizationStatus: { status })
        do {
            _ = try await capture.start()
            Issue.record("expected an authorization error")
        } catch let error as AudioCaptureError {
            #expect(error == .microphoneNotAuthorized(status))
            #expect(error.userFacing.recovery == (status == .restricted ? nil : .openSystemSettings(.microphone)))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("stop is safe when nothing is running, any number of times")
    func stopWhenIdle() async {
        let capture = MicrophoneCapture(authorizationStatus: { .granted })
        await capture.stop()
        await capture.stop()
    }

    @Test("errors are presented with actionable wording")
    func userFacingWording() {
        #expect(AudioCaptureError.noInputDevice.userFacing.title == L10n.Errors.noInputDeviceTitle)
        #expect(AudioCaptureError.deviceLost.userFacing.title == L10n.Errors.micLostTitle)
        #expect(AudioCaptureError.engineStartFailed("boom").userFacing.detail.contains("boom"))
        #expect(AudioCaptureError.microphoneNotAuthorized(.denied).userFacing.title.contains("Microphone"))
    }
}
