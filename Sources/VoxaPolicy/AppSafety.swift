import Foundation

/// What Voxa will do inside a particular app, decided from its bundle identifier.
///
/// Driving another app through its interface can do anything a person at the keyboard could. Most of that is what the user
/// asked for, but a few kinds of app turn a keystroke into something much bigger: a terminal runs whatever is typed, a
/// password manager holds the keys to everything, and the system's own settings change the machine. This is a short list,
/// kept by hand, for those. It is a second line of defence, not the first: the policy's confirmation rules still apply to
/// everything, and an app that isn't listed is not thereby safe.
public enum AppSafety {
    public enum Restriction: Sendable, Equatable {
        case none
        /// Voxa neither reads nor drives it. The reason is written for the person, and is the model's explanation too.
        case untouchable(reason: String)
        /// Whatever Voxa does there is asked about first, however small (unless the user has given Voxa full control).
        case alwaysAsk(reason: String)
    }

    public static func restriction(bundleID: String?) -> Restriction {
        guard let id = bundleID?.lowercased() else { return .none }
        if terminals.contains(id) {
            return .untouchable(
                reason: "It runs whatever is typed into it, which would get around Voxa's rule against running commands."
            )
        }
        if codeRunners.contains(id) {
            return .untouchable(reason: "It runs scripts, which Voxa only does through its own confirmed script tool.")
        }
        if secretKeepers.contains(id) {
            return .untouchable(reason: "It holds passwords and keys, so Voxa doesn't read it or type into it.")
        }
        if authenticationPrompts.contains(id) {
            return .untouchable(reason: "It is where passwords are typed to approve changes to the Mac. Only you should do that.")
        }
        if ownApp.contains(id) {
            return .untouchable(reason: "It holds Voxa's own settings and approvals, which only you change.")
        }
        if systemSettings.contains(id) {
            return .alwaysAsk(reason: "It changes settings of the Mac.")
        }
        return .none
    }

    /// Whether pressing Return (or Enter) in this app can send something: a message, an email, a post.
    public static func sendsOnReturn(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return sendsOnReturnApps.contains(id)
    }

    // MARK: The lists (lowercase bundle identifiers)

    private static let terminals: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "dev.warp.warp", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "com.termius.mac", "io.alacritty",
    ]

    private static let codeRunners: Set<String> = [
        "com.apple.scripteditor2", "com.apple.automator",
    ]

    private static let secretKeepers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.lastpass.lastpass", "in.sinew.enpass-desktop",
        "com.nordsec.nordpass", "me.proton.pass.electron", "com.apple.keychainaccess", "com.apple.passwords",
    ]

    /// The windows macOS raises to ask for an administrator's password, and the lock screen.
    private static let authenticationPrompts: Set<String> = [
        "com.apple.securityagent", "com.apple.loginwindow",
    ]

    /// Voxa itself. Its Settings decide what it may do, so it must not be able to click through them, however it is asked.
    private static let ownApp: Set<String> = [
        "com.rohitsainier.voxa",
    ]

    private static let systemSettings: Set<String> = [
        "com.apple.systempreferences", "com.apple.diskutility", "com.apple.activitymonitor", "com.apple.migrationassistant",
        "com.apple.bootcampassistant", "com.apple.controlcenter", "com.apple.systemuiserver",
    ]

    private static let sendsOnReturnApps: Set<String> = [
        "com.apple.mobilesms", "com.apple.mail", "com.apple.facetime", "com.tinyspeck.slackmacgap", "com.hnc.discord",
        "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
        "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.outlook", "com.tencent.xinwechat", "us.zoom.xos",
        "com.readdle.smartemail-mac", "com.google.chrome.app.gmail",
    ]
}
