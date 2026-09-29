import Foundation
import VoxaCore

/// The verdict on an address the model wants to open.
public struct URLAssessment: Sendable, Equatable {
    /// The address exactly as it will be opened. Nil when it is blocked.
    public var url: URL?
    public var scheme: String?
    /// The host as a person should read it (lower-case, in its ASCII form).
    public var host: String?
    public var risk: RiskLevel
    public var reasons: [String]
    public var block: String?
}

/// Decides whether, and at what risk, Voxa may open an address on the model's behalf.
///
/// Opening an address is not harmless: it sends a request to whoever runs the site, and the address itself can carry data
/// (the clipboard, a file's text) out in its query string; a `tel:` link starts a call; a `file:` or custom-scheme link can
/// launch other software. So schemes are an allowlist, the address that will be opened is the one that was assessed, and
/// the forms attackers use to make one site look like another are refused or raised to a confirmation.
public enum URLPolicy {
    public static let maxLength = 4_096
    /// Above this the address is carrying data, not naming a page.
    static let largeQueryLength = 800

    public static func assess(_ text: String) -> URLAssessment {
        func blocked(_ reason: String) -> URLAssessment {
            URLAssessment(url: nil, scheme: nil, host: nil, risk: .sensitive, reasons: [], block: reason)
        }

        // Hidden characters are looked for in the text as given: trimming first would quietly remove a trailing one.
        if text.unicodeScalars.contains(where: TextSanitizer.isInvisibleOrReordering) {
            return blocked("The address contains hidden characters.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return blocked("The address is empty.") }
        if trimmed.count > maxLength { return blocked("The address is too long to open safely.") }
        if trimmed.unicodeScalars.contains(where: { $0.properties.isWhitespace }) {
            return blocked("The address contains spaces. Encode them, for example %20.")
        }
        if trimmed.contains("\\") {
            return blocked("The address contains a backslash, which different programs read differently.")
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return blocked("That isn't a complete address. It needs a scheme such as https://.")
        }

        switch scheme {
        case "http", "https":
            return assessWeb(components, scheme: scheme, original: trimmed)
        case "mailto":
            guard let url = components.url else { return blocked("That isn't a valid mail address link.") }
            return URLAssessment(
                url: url,
                scheme: scheme,
                host: nil,
                risk: .reversible,
                reasons: [L10n.Policy.mailtoDraft],
                block: nil
            )
        case "tel", "facetime", "facetime-audio", "sms", "imessage":
            guard let url = components.url else { return blocked("That isn't a valid address.") }
            return URLAssessment(
                url: url,
                scheme: scheme,
                host: nil,
                risk: .sensitive,
                reasons: [L10n.Policy.startsCommunication],
                block: nil
            )
        case "maps", "x-apple.systempreferences":
            guard let url = components.url else { return blocked("That isn't a valid address.") }
            return URLAssessment(url: url, scheme: scheme, host: nil, risk: .reversible, reasons: [], block: nil)
        case "shortcuts":
            return blocked("Use the run_shortcut tool to run a Shortcut, so it can be checked and confirmed.")
        case "file":
            return blocked(
                "Voxa doesn't open file addresses, because opening a file can run it. Use a file tool instead."
            )
        default:
            return blocked("Voxa only opens web, mail, phone, message and map links, not \(scheme): links.")
        }
    }

    // MARK: Web addresses

    private static func assessWeb(_ components: URLComponents, scheme: String, original: String) -> URLAssessment {
        func blocked(_ reason: String) -> URLAssessment {
            URLAssessment(url: nil, scheme: scheme, host: nil, risk: .sensitive, reasons: [], block: reason)
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            return blocked("The address has no website name. Write it as \(scheme)://example.com.")
        }
        // https://apple.com@evil.com goes to evil.com; refuse anything built to look like a different site.
        if components.user != nil || components.password != nil {
            return blocked("The address contains a username or password, which is a common way to disguise a site.")
        }
        // `host` is percent-decoded, and `percentEncodedHost` is normalized, so an encoded name (https://%65vil.com) can
        // only be caught in the text as written.
        if rawAuthority(of: original).contains("%") {
            return blocked("The website name contains encoded characters.")
        }
        guard let url = components.url else { return blocked("That isn't a valid web address.") }

        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var risk = RiskLevel.reversible
        var reasons: [String] = []

        if scheme == "http" { reasons.append(L10n.Policy.notEncrypted) }

        if isInternationalName(host) {
            risk = .sensitive
            reasons.append(L10n.Policy.lookalikeName)
        }
        if let network = localNetworkKind(host) {
            risk = .sensitive
            reasons.append(network.reason)
        }
        let query = components.percentEncodedQuery?.count ?? 0
        if query > largeQueryLength || original.count > 2_000 {
            risk = .sensitive
            reasons.append(L10n.Policy.carriesLotsOfData(original.count))
        }

        return URLAssessment(
            url: url,
            scheme: scheme,
            host: asciiHost(components) ?? host,
            risk: risk,
            reasons: reasons,
            block: nil
        )
    }

    /// The part between `//` and the first `/`, `?` or `#`: everything that decides which site is contacted.
    static func rawAuthority(of address: String) -> String {
        guard let slashes = address.range(of: "//") else { return "" }
        let rest = address[slashes.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The host in its ASCII (punycode) form when the system can produce it, so the confirmation shows what a lookalike really is.
    private static func asciiHost(_ components: URLComponents) -> String? {
        components.encodedHost?.lowercased()
    }

    private static func isInternationalName(_ host: String) -> Bool {
        host.unicodeScalars.contains { $0.value > 127 } || host.split(separator: ".").contains { $0.hasPrefix("xn--") }
    }

    enum LocalNetworkKind {
        case localName
        case privateAddress
        case numericAddress
        case singleLabel

        var reason: String {
            switch self {
            case .localName, .privateAddress, .singleLabel: L10n.Policy.localNetwork
            case .numericAddress: L10n.Policy.rawIPAddress
            }
        }
    }

    /// Whether a host is on the user's own network, or is a bare number rather than a name.
    static func localNetworkKind(_ host: String) -> LocalNetworkKind? {
        let localSuffixes = [
            ".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".intranet", ".localdomain", ".home.arpa",
        ]
        if host == "localhost" || localSuffixes.contains(where: host.hasSuffix) { return .localName }

        // IPv6 (URLComponents drops the brackets).
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return .numericAddress }
            return isPrivate(address) ? .privateAddress : .numericAddress
        }
        // IPv4 in any spelling `inet_aton` accepts: 127.1, 0x7f.0.0.1, 2130706433 and so on.
        if let first = host.first, first.isNumber {
            var address = in_addr()
            guard inet_aton(host, &address) != 0 else { return .numericAddress }
            return isPrivate(address) ? .privateAddress : .numericAddress
        }
        if !host.contains(".") { return .singleLabel }
        return nil
    }

    private static func isPrivate(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = value >> 24
        let second = (value >> 16) & 0xFF
        return first == 0 || first == 10 || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
            || (first == 100 && (64...127).contains(second))
    }

    private static func isPrivate(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        // ::ffff:a.b.c.d maps an IPv4 address; judge the IPv4 part.
        let isMapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        if isMapped {
            let v4 = in_addr(
                s_addr: UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
            )
            return isPrivate(v4)
        }
        return isLoopback || isUnspecified || isUniqueLocal || isLinkLocal
    }
}
