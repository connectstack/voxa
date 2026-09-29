import Foundation
import Testing
import VoxaCore
@testable import VoxaPermissions
import VoxaTestSupport

@MainActor
@Suite("PermissionsModel")
struct PermissionsModelTests {
    private let kinds: [PermissionKind] = [.microphone, .calendars, .accessibility, .automation]

    private func model(_ statuses: [PermissionKind: PermissionStatus]) -> (PermissionsModel, FakePermissions) {
        let fake = FakePermissions()
        fake.statuses = statuses
        return (PermissionsModel(permissions: fake, kinds: kinds), fake)
    }

    @Test("it reads every listed status when created, without asking for anything")
    func readsStatuses() {
        let (model, fake) = model([.microphone: .granted, .calendars: .denied, .accessibility: .notDetermined, .automation: .notDetermined])
        #expect(model.status(of: .calendars) == .denied)
        #expect(model.status(of: .accessibility) == .notDetermined)
        #expect(fake.requested.isEmpty, "reading never prompts")
    }

    @Test("each state offers the right button")
    func actions() {
        let (model, _) = model([
            .microphone: .granted, .calendars: .denied, .accessibility: .notDetermined, .automation: .notDetermined,
        ])
        #expect(model.action(for: .microphone) == .none)
        #expect(model.action(for: .calendars) == .openSystemSettings, "a denied permission can only be fixed in System Settings")
        #expect(model.action(for: .accessibility) == .allow)
        #expect(model.action(for: .automation) == .openSystemSettings, "Automation is asked per app, so there is nothing to allow")
    }

    @Test("Accessibility and Screen Recording offer both buttons until they are on, because the switch is flipped in System Settings")
    func systemSettingsKinds() {
        let fake = FakePermissions()
        fake.statuses = [.accessibility: .notDetermined, .screenRecording: .notDetermined, .calendars: .notDetermined]
        let model = PermissionsModel(permissions: fake, kinds: [.accessibility, .screenRecording, .calendars])
        #expect(model.actions(for: .accessibility) == [.allow, .openSystemSettings])
        #expect(model.actions(for: .screenRecording) == [.allow, .openSystemSettings])
        #expect(model.actions(for: .calendars) == [.allow], "a prompt is enough for these")
        #expect(model.action(for: .accessibility) == .allow, "and the first thing offered is still the prompt")

        fake.statuses[.accessibility] = .granted
        model.refresh()
        #expect(model.actions(for: .accessibility).isEmpty)
    }

    @Test("every state has the right set of buttons")
    func allActions() {
        let fake = FakePermissions()
        let model = PermissionsModel(permissions: fake, kinds: [.microphone, .automation])
        for (kind, status, expected) in [
            (PermissionKind.microphone, PermissionStatus.granted, [PermissionsModel.Action]()),
            (.microphone, .notDetermined, [.allow]),
            (.microphone, .denied, [.openSystemSettings]),
            (.microphone, .restricted, []),
            (.automation, .notDetermined, [.openSystemSettings]),
            (.automation, .granted, []),
        ] {
            fake.statuses[kind] = status
            model.refresh()
            #expect(model.actions(for: kind) == expected, "\(kind) \(status)")
        }
    }

    @Test("a restricted permission offers nothing: the user can't change it")
    func restricted() {
        let (model, _) = model([.calendars: .restricted])
        #expect(model.action(for: .calendars) == .none)
    }

    @Test("allowing asks macOS once, then shows the new status")
    func allow() async {
        let (model, fake) = model([.calendars: .notDetermined])
        await model.request(.calendars)
        #expect(fake.requested == [.calendars])
        #expect(model.status(of: .calendars) == .granted)
        #expect(model.requesting == nil)
    }

    @Test("a refused prompt shows as off")
    func refused() async {
        let (model, fake) = model([.calendars: .notDetermined])
        fake.grantOnRequest = false
        await model.request(.calendars)
        #expect(model.status(of: .calendars) == .denied)
        #expect(model.action(for: .calendars) == .openSystemSettings)
    }

    @Test("only one prompt at a time: a second request while one is up is ignored")
    func oneAtATime() async {
        let (model, fake) = model([.calendars: .notDetermined, .accessibility: .notDetermined])
        let gate = AsyncGate()
        fake.whileRequesting = { await gate.wait() }

        let first = Task { await model.request(.calendars) }
        #expect(await waitUntil { model.requesting == .calendars })
        await model.request(.accessibility)
        #expect(fake.requested == [.calendars])

        await gate.open()
        await first.value
        #expect(model.requesting == nil)
    }

    @Test("a change made in System Settings shows up on the next refresh")
    func refresh() {
        let (model, fake) = model([.accessibility: .notDetermined])
        #expect(!model.allGranted)
        fake.statuses[.accessibility] = .granted
        fake.statuses[.microphone] = .granted
        fake.statuses[.calendars] = .granted
        fake.statuses[.automation] = .granted
        model.refresh()
        #expect(model.status(of: .accessibility) == .granted)
        #expect(model.allGranted)
    }

    @Test("performing an action does what the button says")
    func perform() async {
        let (model, fake) = model([.calendars: .notDetermined, .accessibility: .denied])
        await model.perform(.allow, for: .calendars)
        await model.perform(.openSystemSettings, for: .accessibility)
        await model.perform(.none, for: .microphone)
        #expect(fake.requested == [.calendars])
        #expect(fake.openedSettings == [.accessibility])
    }
}
