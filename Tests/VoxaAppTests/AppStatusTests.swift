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

@Suite("MenuBarIcon")
struct MenuBarIconTests {
    private let problem = UserFacingError(title: "Microphone access is needed", detail: "Allow it in System Settings.")

    @Test("with nothing going on, the icon says whether continuous listening has the microphone open")
    func idle() {
        #expect(MenuBarIcon.symbolName(status: .idle, handsFree: .off) == "mic")
        #expect(MenuBarIcon.symbolName(status: .idle, handsFree: .listening) == "ear")
        #expect(MenuBarIcon.symbolName(status: .idle, handsFree: .starting) == "ear")
        #expect(MenuBarIcon.symbolName(status: .idle, handsFree: .unavailable(problem)) == "mic.slash")
        #expect(MenuBarIcon.symbolName(status: .idle, handsFree: .paused(.working)) == "mic")
    }

    @Test("whatever else Voxa is doing shows as it always did, whatever listening is up to")
    func busy() {
        for status in [AppStatus.listening, .thinking, .acting, .confirming, .error] {
            for state in [HandsFreeState.off, .listening, .unavailable(problem), .paused(.speaking)] {
                #expect(MenuBarIcon.symbolName(status: status, handsFree: state) == status.symbolName, "\(status) \(state)")
            }
        }
    }

    @Test("the hands-free icons are not the ones the other states use")
    func distinct() {
        let others = Set([AppStatus.idle, .listening, .thinking, .acting, .confirming, .error].map(\.symbolName))
        #expect(!others.contains("ear") && !others.contains("mic.slash"))
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
        #expect(environment.handsFree.state == .off)
    }
}
