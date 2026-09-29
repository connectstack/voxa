import Foundation
import Testing
@testable import VoxaPolicy

@Suite("AppSafety")
struct AppSafetyTests {
    @Test("terminals are off limits, because typing into them runs commands", arguments: [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ])
    func terminals(bundleID: String) {
        guard case .untouchable(let reason) = AppSafety.restriction(bundleID: bundleID) else {
            Issue.record("\(bundleID) should be untouchable")
            return
        }
        #expect(reason.contains("runs whatever is typed"))
    }

    @Test("script editors are off limits, because they would get around the confirmed script tool", arguments: [
        "com.apple.ScriptEditor2", "com.apple.Automator",
    ])
    func codeRunners(bundleID: String) {
        #expect(AppSafety.restriction(bundleID: bundleID) != .none)
    }

    @Test("password managers, keychain, and the admin password prompt are off limits", arguments: [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.SecurityAgent", "com.apple.loginwindow",
    ])
    func secrets(bundleID: String) {
        guard case .untouchable = AppSafety.restriction(bundleID: bundleID) else {
            Issue.record("\(bundleID) should be untouchable")
            return
        }
    }

    @Test("apps that change the Mac are allowed, but every action in them is asked about", arguments: [
        "com.apple.systempreferences", "com.apple.DiskUtility", "com.apple.ActivityMonitor", "com.apple.controlcenter",
    ])
    func alwaysAsk(bundleID: String) {
        guard case .alwaysAsk(let reason) = AppSafety.restriction(bundleID: bundleID) else {
            Issue.record("\(bundleID) should always ask")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("everything else, and an unknown app, has no restriction", arguments: [
        "com.apple.Safari", "com.apple.Notes", "com.apple.TextEdit", "com.microsoft.VSCode", "com.example.unknown",
    ])
    func ordinary(bundleID: String) {
        #expect(AppSafety.restriction(bundleID: bundleID) == .none)
    }

    @Test("a missing bundle identifier means no restriction, and case doesn't matter")
    func edges() {
        #expect(AppSafety.restriction(bundleID: nil) == .none)
        #expect(AppSafety.restriction(bundleID: "") == .none)
        #expect(AppSafety.restriction(bundleID: "COM.APPLE.TERMINAL") != .none)
    }

    @Test("Return sends in chat and mail apps, not in ordinary ones", arguments: [
        ("com.apple.MobileSMS", true), ("com.apple.mail", true), ("com.tinyspeck.slackmacgap", true),
        ("com.hnc.Discord", true), ("net.whatsapp.WhatsApp", true), ("com.apple.TextEdit", false), ("com.apple.Notes", false),
    ])
    func sends(bundleID: String, expected: Bool) {
        #expect(AppSafety.sendsOnReturn(bundleID: bundleID) == expected)
    }

    @Test("no app is in two lists that disagree about it")
    func consistency() {
        // A terminal must never also be merely "ask", and a chat app must not be untouchable by accident.
        #expect(AppSafety.restriction(bundleID: "com.apple.MobileSMS") == .none)
        #expect(AppSafety.restriction(bundleID: "com.apple.mail") == .none)
    }
}
