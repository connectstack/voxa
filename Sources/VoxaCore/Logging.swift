import os

/// Central `os.Logger` instances, one per subsystem area.
///
/// Logging rules (enforced in review, not by the compiler):
/// - Never log the API key, tokens or any credential.
/// - Never log a full transcript, clipboard text, screen text or tool payload at the default level.
///   User content may only appear at `.debug` and must be interpolated with `privacy: .private`.
/// - Counts, durations, states and error *categories* are fine at `.info` and above.
public enum Log {
    public static let subsystem = "com.rohitsainier.voxa"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let hud = Logger(subsystem: subsystem, category: "hud")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let llm = Logger(subsystem: subsystem, category: "llm")
    public static let agent = Logger(subsystem: subsystem, category: "agent")
    public static let policy = Logger(subsystem: subsystem, category: "policy")
    public static let tools = Logger(subsystem: subsystem, category: "tools")
}
