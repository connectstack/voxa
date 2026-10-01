import Foundation
import Testing
@testable import VoxaSettings

@MainActor
@Suite("Siri setup")
struct SiriSetupTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let suite = "com.rohitsainier.voxa.tests.siri.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test("Hey Siri on, and Siri on: what it takes to talk to Voxa without touching anything")
    func ready() {
        let siri = SystemSiri(
            siri: defaults(["VoiceTriggerUserEnabled": true]),
            assistant: defaults(["Assistant Enabled": true])
        )
        #expect(siri.setup() == SiriSetup(isEnabled: true, listensForHeySiri: true))
    }

    @Test("Siri on but not listening for its name: the settings say to turn Hey Siri on")
    func heySiriOff() {
        let siri = SystemSiri(
            siri: defaults(["VoiceTriggerUserEnabled": false]),
            assistant: defaults(["Assistant Enabled": true])
        )
        #expect(siri.setup() == SiriSetup(isEnabled: true, listensForHeySiri: false))
    }

    @Test("Siri switched off is reported as off")
    func siriOff() {
        let siri = SystemSiri(siri: defaults([:]), assistant: defaults(["Assistant Enabled": false]))
        #expect(!siri.setup().isEnabled)
    }

    @Test("a Mac that says nothing about Siri is taken to have it on and not listening for its name, so Voxa doesn't nag")
    func silence() {
        let siri = SystemSiri(siri: defaults([:]), assistant: defaults([:]))
        #expect(siri.setup() == SiriSetup(isEnabled: true, listensForHeySiri: false))
    }

    @Test("the inert Siri, which the previews and tests use, changes nothing")
    func inert() {
        let siri = InertSiri()
        #expect(siri.setup() == SiriSetup(isEnabled: true, listensForHeySiri: false))
        siri.openSettings()
    }
}
