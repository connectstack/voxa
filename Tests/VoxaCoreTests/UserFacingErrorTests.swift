import Foundation
import Testing
@testable import VoxaCore

@Suite("UserFacingError")
struct UserFacingErrorTests {
    private struct Custom: UserFacingConvertible {
        var userFacing: UserFacingError { UserFacingError(title: "Custom title", detail: "Custom detail") }
    }

    private struct Plain: Error, LocalizedError {
        var errorDescription: String? { "the plain reason" }
    }

    @Test("a UserFacingError passes through untouched")
    func passthrough() {
        let error = UserFacingError(title: "T", detail: "D", recovery: .openAppSettings)
        #expect(UserFacingError.describing(error) == error)
    }

    @Test("convertible errors keep their own wording")
    func convertible() {
        let described = UserFacingError.describing(Custom())
        #expect(described.title == "Custom title")
        #expect(described.detail == "Custom detail")
    }

    @Test("unknown errors get a generic title and the system's description as detail")
    func generic() {
        let described = UserFacingError.describing(Plain())
        #expect(described.title == L10n.Errors.genericTitle)
        #expect(described.detail == "the plain reason")
    }

    @Test("every permission has a fix-it error that names it and opens the right pane", arguments: PermissionKind.allCases)
    func permissionErrors(kind: PermissionKind) {
        let denied = UserFacingError.permissionRequired(kind, status: .denied)
        #expect(denied.title.contains(kind.displayName))
        #expect(denied.detail.contains(kind.displayName))
        #expect(denied.recovery == .openSystemSettings(kind))

        let asked = UserFacingError.permissionRequired(kind, status: .notDetermined)
        #expect(asked.title != denied.title)
    }

    @Test("restricted access explains itself but offers no button that can't help")
    func restricted() {
        let error = UserFacingError.permissionRequired(.microphone, status: .restricted)
        #expect(error.recovery == nil)
        #expect(error.detail.contains("administrator"))
    }

    @Test("it is usable as a LocalizedError")
    func localizedError() {
        let error: any Error = UserFacingError(title: "Title", detail: "Detail")
        #expect(error.localizedDescription == "Title")
        #expect((error as? any LocalizedError)?.failureReason == "Detail")
    }
}
