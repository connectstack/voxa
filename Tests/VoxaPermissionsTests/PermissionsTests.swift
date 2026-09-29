import Foundation
import Testing
import VoxaCore
@testable import VoxaPermissions
import VoxaTestSupport

@MainActor
@Suite("ensureGranted")
struct EnsureGrantedTests {
    @Test("nothing to do when everything is granted")
    func allGranted() async {
        let permissions = FakePermissions()
        #expect(await permissions.ensureGranted([.microphone, .speechRecognition]) == nil)
        #expect(permissions.requested.isEmpty)
    }

    @Test("an undetermined permission is requested, and proceeding is fine once granted")
    func requestThenGranted() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .notDetermined
        #expect(await permissions.ensureGranted([.microphone]) == nil)
        #expect(permissions.requested == [.microphone])
    }

    @Test("a refused prompt becomes an error that opens the right System Settings pane")
    func requestThenDenied() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .notDetermined
        permissions.grantOnRequest = false

        let error = await permissions.ensureGranted([.microphone])
        #expect(error == .permissionRequired(.microphone, status: .denied))
        #expect(error?.recovery == .openSystemSettings(.microphone))
    }

    @Test("an already-denied permission is not re-requested (macOS wouldn't show a prompt)")
    func alreadyDenied() async {
        let permissions = FakePermissions()
        permissions.statuses[.speechRecognition] = .denied
        let error = await permissions.ensureGranted([.speechRecognition])
        #expect(error == .permissionRequired(.speechRecognition, status: .denied))
        #expect(permissions.requested.isEmpty)
    }

    @Test("restricted access has no button")
    func restricted() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .restricted
        #expect(await permissions.ensureGranted([.microphone])?.recovery == nil)
    }

    @Test("it stops at the first problem and does not prompt for later permissions")
    func stopsAtFirstProblem() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .denied
        permissions.statuses[.speechRecognition] = .notDetermined
        _ = await permissions.ensureGranted([.microphone, .speechRecognition])
        #expect(permissions.requested.isEmpty)
    }

    @Test("prompts happen in order, one after another")
    func inOrder() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .notDetermined
        permissions.statuses[.speechRecognition] = .notDetermined
        _ = await permissions.ensureGranted([.microphone, .speechRecognition])
        #expect(permissions.requested == [.microphone, .speechRecognition])
    }
}

@MainActor
@Suite("SystemPermissionsManager")
struct SystemPermissionsManagerTests {
    @Test("every permission deep-links into Privacy & Security", arguments: PermissionKind.allCases)
    func deepLinks(kind: PermissionKind) {
        let url = SystemSettingsPane.url(for: kind)
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.absoluteString.contains("com.apple.preference.security"))
        #expect(url.absoluteString.contains("Privacy_"))
    }

    @Test("the deep links are all different")
    func distinctLinks() {
        let urls = Set(PermissionKind.allCases.map { SystemSettingsPane.url(for: $0) })
        #expect(urls.count == PermissionKind.allCases.count)
    }

    @Test("opening settings goes through the injected opener")
    func opener() {
        var opened: [URL] = []
        let manager = SystemPermissionsManager(openURL: { opened.append($0) })
        manager.openSystemSettings(for: .microphone)
        #expect(opened == [SystemSettingsPane.url(for: .microphone)])
    }

    @Test("status can be read for every kind without prompting or crashing")
    func statusIsReadable() {
        let manager = SystemPermissionsManager(openURL: { _ in })
        for kind in PermissionKind.allCases {
            _ = manager.status(of: kind)
        }
    }
}
