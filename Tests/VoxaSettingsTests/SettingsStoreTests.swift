import Foundation
import Testing
import VoxaCore
@testable import VoxaSettings

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    /// An isolated defaults domain so tests never touch (or depend on) the user's real preferences.
    private func makeDefaults() -> UserDefaults {
        let suite = "com.rohitsainier.voxa.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh install gets the defaults")
    func defaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.current == AppSettings())
    }

    @Test("changes are persisted and restored by a new store")
    func persistence() {
        let defaults = makeDefaults()
        let first = SettingsStore(defaults: defaults)
        first.current.speechEngine = .appleClassic
        first.current.localeIdentifier = "hi_IN"
        first.current.maxRecordingSeconds = 20

        let second = SettingsStore(defaults: defaults)
        #expect(second.current.speechEngine == .appleClassic)
        #expect(second.current.localeIdentifier == "hi_IN")
        #expect(second.current.maxRecordingSeconds == 20)
    }

    @Test("corrupt stored data falls back to the defaults instead of crashing")
    func corruptData() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.defaultsKey)
        #expect(SettingsStore(defaults: defaults).current == AppSettings())
    }

    @Test("settings written by another version keep the values this version understands")
    func partialData() {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"localeIdentifier":"fr_FR","fromTheFuture":1}"#.utf8), forKey: SettingsStore.defaultsKey)
        let store = SettingsStore(defaults: defaults)
        #expect(store.current.localeIdentifier == "fr_FR")
        #expect(store.current.speechEngine == .appleAutomatic)
    }
}
