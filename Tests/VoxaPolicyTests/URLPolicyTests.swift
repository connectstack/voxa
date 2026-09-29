import Foundation
import Testing
import VoxaCore
@testable import VoxaPolicy

@Suite("URLPolicy")
struct URLPolicyTests {
    private func risk(_ text: String) -> RiskLevel? {
        let result = URLPolicy.assess(text)
        return result.block == nil ? result.risk : nil
    }

    @Test("ordinary web pages open with a notice and no warnings", arguments: [
        "https://www.apple.com", "https://www.google.com/search?q=swift+concurrency", "https://en.wikipedia.org/wiki/Swift_(programming_language)",
        "HTTPS://EXAMPLE.COM/Path", "https://example.com:8443/x?y=1#frag", "https://sub.domain.example.co.uk/",
    ])
    func ordinary(text: String) {
        let result = URLPolicy.assess(text)
        #expect(result.block == nil)
        #expect(result.risk == .reversible)
        #expect(result.reasons.isEmpty)
        #expect(result.url != nil)
        #expect(result.scheme == "https")
    }

    @Test("http works but says it isn't encrypted")
    func plainHTTP() {
        let result = URLPolicy.assess("http://example.com")
        #expect(result.risk == .reversible)
        #expect(result.reasons == [L10n.Policy.notEncrypted])
    }

    @Test("the host is reported lower-case, without the port or path")
    func host() {
        #expect(URLPolicy.assess("https://WWW.Example.COM:8080/a").host == "www.example.com")
    }

    @Test("mail links open a draft; phone and message links start something and are sensitive")
    func schemes() {
        #expect(risk("mailto:someone@example.com?subject=Hi") == .reversible)
        #expect(risk("maps://?q=coffee") == .reversible)
        #expect(risk("x-apple.systempreferences:com.apple.preference.security") == .reversible)
        for text in ["tel:+15551234567", "facetime://someone@example.com", "facetime-audio://x@y.com", "sms:+15551234567", "imessage://x@y.com"] {
            #expect(risk(text) == .sensitive, "\(text)")
        }
    }

    /// Schemes that run code, read local files, reach other services or hand the request to other software.
    @Test("every other scheme is refused", arguments: [
        "file:///Applications/Utilities/Terminal.app", "file:///tmp/x.command", "javascript:alert(1)", "data:text/html,<script>1</script>",
        "ftp://example.com/x", "ssh://root@host", "smb://server/share", "afp://server/share", "vnc://host", "telnet://host",
        "applescript://com.apple.scripteditor?action=new&script=say%20hi", "x-scripteditor://x", "vscode://file/etc/passwd",
        "slack://open", "itms-services://?action=download-manifest&url=https://evil.example/x.plist", "blob:https://x.com/y",
        "x-man-page://ls", "raycast://extensions/x", "zoommtg://zoom.us/join?confno=1",
    ])
    func blockedSchemes(text: String) {
        let result = URLPolicy.assess(text)
        #expect(result.block != nil, "\(text)")
        #expect(result.url == nil)
    }

    @Test("Shortcuts links are redirected to the run_shortcut tool")
    func shortcutsLinks() {
        #expect(URLPolicy.assess("shortcuts://run-shortcut?name=Anything").block?.contains("run_shortcut") == true)
    }

    @Test("addresses built to disguise the real site are refused", arguments: [
        "https://apple.com@evil.example.com/", "https://user:password@example.com/", "https://evil.example.com\\@apple.com/",
        "https:evil.example.com", "https:///evil.example.com", "https://", "https://%65vil.example.com/",
        "https://exa mple.com", "https://example.com/a b", "https://example.com/\u{200B}", "", "   ", "example.com", "://x",
    ])
    func disguised(text: String) {
        #expect(URLPolicy.assess(text).block != nil, "\(text.debugDescription)")
    }

    @Test("an address that's far too long is refused")
    func tooLong() {
        #expect(URLPolicy.assess("https://example.com/" + String(repeating: "a", count: URLPolicy.maxLength)).block != nil)
    }

    @Test("devices on the user's own network and bare IP numbers need confirmation", arguments: [
        "http://localhost:8080/", "https://localhost", "http://127.0.0.1/", "http://127.1/", "http://192.168.1.1/admin", "http://10.0.0.5/",
        "http://172.16.0.1/", "http://172.31.255.255/", "http://169.254.169.254/latest/meta-data/", "http://100.64.0.1/", "http://0.0.0.0/",
        "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:192.168.0.1]/",
        "http://2130706433/", "http://0x7f.0.0.1/", "http://017700000001/",
        "http://router/", "http://printer.local/", "https://nas.lan/", "https://intranet.corp/", "http://foo.localhost/", "http://x.home.arpa/",
        "http://8.8.8.8/", "https://172.32.0.1/", "http://[2001:db8::1]/",
    ])
    func localNetwork(text: String) {
        let result = URLPolicy.assess(text)
        #expect(result.block == nil, "\(text)")
        #expect(result.risk == .sensitive, "\(text)")
        #expect(!result.reasons.isEmpty, "\(text)")
    }

    @Test("a private IP is described as being on your network, a public one as a bare number")
    func localVersusNumeric() {
        #expect(URLPolicy.assess("https://192.168.1.1/").reasons == [L10n.Policy.localNetwork])
        #expect(URLPolicy.assess("https://8.8.8.8/").reasons == [L10n.Policy.rawIPAddress])
    }

    @Test("look-alike (international) site names are sensitive and shown in their ASCII form")
    func lookalikes() {
        let cyrillic = URLPolicy.assess("https://аpple.com/")   // first letter is Cyrillic
        #expect(cyrillic.block == nil)
        #expect(cyrillic.risk == .sensitive)
        #expect(cyrillic.reasons.contains(L10n.Policy.lookalikeName))
        #expect(cyrillic.host?.hasPrefix("xn--") == true, "shows the punycode, not the disguise: \(cyrillic.host ?? "")")

        let punycode = URLPolicy.assess("https://xn--pple-43d.com/")
        #expect(punycode.risk == .sensitive)
    }

    @Test("an address that carries a lot of data is sensitive, because opening it sends that data to the site")
    func carriesData() {
        let leak = "https://example.com/collect?d=" + String(repeating: "A", count: URLPolicy.largeQueryLength + 10)
        let result = URLPolicy.assess(leak)
        #expect(result.risk == .sensitive)
        #expect(result.reasons.count == 1)
        #expect(risk("https://example.com/search?q=" + String(repeating: "a", count: 200)) == .reversible)
    }

    @Test("what will be opened is exactly what was assessed")
    func opensAssessedURL() {
        let result = URLPolicy.assess("  https://example.com/a?b=c \n")
        #expect(result.url?.absoluteString == "https://example.com/a?b=c")
    }
}
