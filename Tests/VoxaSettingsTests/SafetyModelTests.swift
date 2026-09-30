import Foundation
import Testing
import VoxaCore
@testable import VoxaSettings

@MainActor
@Suite("SafetyModel: full control")
struct SafetyModelTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.rohitsainier.voxa.tests.safety.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh install has it off")
    func offByDefault() {
        let store = SettingsStore(defaults: makeDefaults())
        let model = SafetyModel(store: store)
        #expect(!model.fullControl && !model.isAsking)
    }

    @Test("flipping the switch on asks first and changes nothing until the answer is yes")
    func turningOnAsks() {
        let store = SettingsStore(defaults: makeDefaults())
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        #expect(model.isAsking)
        #expect(!store.current.fullControl, "nothing changes on the flip itself")
        #expect(!model.fullControl)
    }

    @Test("Give Full Control turns it on, closes the question, and is saved")
    func giving() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        model.giveFullControl()
        #expect(store.current.fullControl && model.fullControl)
        #expect(!model.isAsking)
        #expect(SettingsStore(defaults: defaults).current.fullControl, "a new store, like a relaunch, still has it")
    }

    @Test("Keep Asking, or Esc, leaves it off and closes the question")
    func keepingAsking() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        model.keepAsking()
        #expect(!store.current.fullControl && !model.isAsking)
        #expect(!SettingsStore(defaults: defaults).current.fullControl)
    }

    @Test("turning it off is immediate and needs no question")
    func turningOff() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.current.fullControl = true
        let model = SafetyModel(store: store)
        model.setFullControl(false)
        #expect(!store.current.fullControl && !model.isAsking)
        #expect(!SettingsStore(defaults: defaults).current.fullControl)
    }

    @Test("turning it on when it already is on doesn't ask again")
    func alreadyOn() {
        let store = SettingsStore(defaults: makeDefaults())
        store.current.fullControl = true
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        #expect(!model.isAsking && store.current.fullControl)
    }

    @Test("switching it off while the question is up withdraws the question")
    func offWhileAsking() {
        let store = SettingsStore(defaults: makeDefaults())
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        model.setFullControl(false)
        #expect(!model.isAsking && !store.current.fullControl)
    }

    @Test("something else turning it off, such as the menu-bar item, shows in the model at once")
    func offElsewhere() {
        let store = SettingsStore(defaults: makeDefaults())
        let model = SafetyModel(store: store)
        model.setFullControl(true)
        model.giveFullControl()
        store.current.fullControl = false
        #expect(!model.fullControl)
    }
}
