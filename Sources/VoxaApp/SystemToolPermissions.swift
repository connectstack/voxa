import Foundation
import VoxaAgent
import VoxaCore
import VoxaPermissions

/// The agent's permission gate, backed by the real permissions manager: a tool that needs Calendar access asks macOS for it
/// (once), and one the user has refused ends the command with an error that has a button for System Settings.
struct SystemToolPermissions: ToolPermissionGranting {
    let permissions: any PermissionsProviding

    func ensureGranted(_ kinds: [PermissionKind]) async -> UserFacingError? {
        await permissions.ensureGranted(kinds)
    }
}

/// Permission answers that are made up, for development runs that need to see what a refusal looks like without anyone
/// touching System Settings. Anything not listed is answered by the real manager.
///
/// Only ever created from `VOXA_DEBUG_TOOL_PERMISSIONS`, which Release builds ignore.
@MainActor
final class ScriptedPermissions: PermissionsProviding {
    private var scripted: [PermissionKind: PermissionStatus]
    private let real: any PermissionsProviding

    init(_ scripted: [PermissionKind: PermissionStatus], real: any PermissionsProviding) {
        self.scripted = scripted
        self.real = real
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        scripted[kind] ?? real.status(of: kind)
    }

    /// A pretend prompt: "not asked yet" is answered yes, as if the user pressed Allow; a refusal stays a refusal.
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        guard let current = scripted[kind] else { return await real.request(kind) }
        if current == .notDetermined { scripted[kind] = .granted }
        return scripted[kind] ?? current
    }

    func openSystemSettings(for kind: PermissionKind) {
        real.openSystemSettings(for: kind)
    }
}
