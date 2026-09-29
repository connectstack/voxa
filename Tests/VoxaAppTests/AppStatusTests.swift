import Foundation
import Testing
@testable import VoxaApp
import VoxaCore

@Suite("AppStatus")
struct AppStatusTests {
    @Test("every status has a distinct menu-bar symbol")
    func symbols() {
        let statuses: [AppStatus] = [.idle, .listening, .thinking, .acting, .confirming, .error]
        #expect(Set(statuses.map(\.symbolName)).count == statuses.count)
    }
}

@MainActor
@Suite("AppEnvironment")
struct AppEnvironmentTests {
    @Test("the real object graph can be built without side effects, and starts idle")
    func builds() {
        let suite = "com.rohitsainier.voxa.tests.env.\(UUID().uuidString)"
        let environment = AppEnvironment(defaults: UserDefaults(suiteName: suite)!)
        #expect(environment.session.status == .idle)
        #expect(environment.session.phase == .idle)
    }
}
