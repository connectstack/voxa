import VoxaCore

/// Makes sure the system permissions a tool needs are in place before it runs, so the first "what's on my calendar?" asks
/// macOS for Calendar access instead of failing with an error nobody can act on.
public protocol ToolPermissionGranting: Sendable {
    /// Returns nil when every permission is granted (asking macOS about the ones the user hasn't been asked about yet), or a
    /// ready-to-show error, with a button that fixes it, for the first one that isn't.
    func ensureGranted(_ kinds: [PermissionKind]) async -> UserFacingError?
}

/// Grants everything without asking. For tests and developer tools, where no system permission is involved.
public struct UnrestrictedToolPermissions: ToolPermissionGranting {
    public init() {}

    public func ensureGranted(_ kinds: [PermissionKind]) async -> UserFacingError? { nil }
}
