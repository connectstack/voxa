import AppKit
import Foundation
import os
import VoxaPolicy

public struct InstalledApp: Sendable, Equatable, Hashable {
    /// The name people say and see ("Safari"), without `.app`.
    public var name: String
    public var bundleID: String?
    public var url: URL

    public init(name: String, bundleID: String? = nil, url: URL) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
    }
}

/// The apps that can be opened by name.
public protocol AppCataloging: Sendable {
    func apps() -> [InstalledApp]
}

/// Finds applications in the standard folders. The list is cached briefly: a command may resolve a name more than once.
public final class SystemAppCatalog: AppCataloging {
    private struct Cache {
        var apps: [InstalledApp] = []
        var loadedAt: Date?
    }

    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    private let directories: [URL]
    private let standalone: [URL]
    private let lifetime: TimeInterval

    public init(directories: [URL]? = nil, standaloneApps: [URL]? = nil, cacheLifetime: TimeInterval = 30) {
        self.directories = directories ?? Self.standardDirectories
        self.standalone = standaloneApps ?? (directories == nil ? Self.standaloneApps : [])
        self.lifetime = cacheLifetime
    }

    /// Where user-facing apps live. `/System/Library/CoreServices` is deliberately not scanned as a whole (it is full of
    /// helpers such as the login window); only Finder is taken from it.
    static var standardDirectories: [URL] {
        var paths = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ]
        paths.append(NSHomeDirectory() + "/Applications")
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let standaloneApps = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

    public func apps() -> [InstalledApp] {
        if let cached = cache.withLock({ state -> [InstalledApp]? in
            guard let loaded = state.loadedAt, Date().timeIntervalSince(loaded) < lifetime else { return nil }
            return state.apps
        }) {
            return cached
        }
        let found = scan()
        cache.withLock {
            $0.apps = found
            $0.loadedAt = Date()
        }
        return found
    }

    private func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        var result: [InstalledApp] = []
        for directory in directories {
            // Not `.skipsHiddenFiles`: macOS flags some real apps hidden (Safari's entry in /Applications is a hidden
            // symlink into a system volume). Names that start with a dot are still skipped.
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []
            ) else { continue }
            for url in entries where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
                if let app = Self.describe(url) { result.append(app) }
            }
        }
        for url in standalone {
            if let app = Self.describe(url) { result.append(app) }
        }
        return result
    }

    /// Reads an app bundle's name and identifier, skipping background helpers that aren't apps a person would open.
    static func describe(_ url: URL) -> InstalledApp? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        if info["LSBackgroundOnly"] as? Bool == true || info["LSBackgroundOnly"] as? String == "1" { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = fileName }
        return InstalledApp(name: cleaned(name), bundleID: info["CFBundleIdentifier"] as? String, url: url)
    }

    /// App names reach the model in messages ("Did the user mean…") and the user in a confirmation, and anyone who can put an
    /// app on the disk chooses its name. So a name is one short line of plain text: no line breaks, no invisible characters.
    static func cleaned(_ name: String) -> String {
        let flattened = TextSanitizer.forModel(name)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(80))
    }
}

/// Opens applications and addresses. The one place that touches `NSWorkspace`.
public protocol AppOpening: Sendable {
    func open(_ app: InstalledApp) async throws
    /// Opens `url` in the default handler, or in `app` when given.
    func open(_ url: URL, in app: InstalledApp?) async throws
}

public struct WorkspaceOpener: AppOpening {
    public init() {}

    public func open(_ app: InstalledApp) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
    }

    public func open(_ url: URL, in app: InstalledApp?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }
}

// MARK: - Name matching

/// Turns what the user said into an installed app. Speech recognition mishears names ("sapphire" for "Safari"), so this
/// is forgiving where that is safe (case, spacing, `.app`, a distinctive part of a name) and never guesses between two
/// plausible apps or across a large spelling gap: it reports the candidates instead, so the model can ask.
public enum AppMatcher {
    public enum Resolution: Equatable {
        case found(InstalledApp)
        case ambiguous([InstalledApp])
        case notFound(suggestions: [String])
    }

    public static func resolve(_ query: String, in apps: [InstalledApp]) -> Resolution {
        let wanted = normalize(query)
        guard !wanted.isEmpty else { return .notFound(suggestions: []) }

        // 1. A bundle identifier.
        let looksLikeBundleID = query.contains(".") && !query.contains(" ")
        if looksLikeBundleID, let match = apps.first(where: { $0.bundleID?.lowercased() == query.lowercased() }) {
            return .found(match)
        }
        // 2. The exact name, however it is spelled or spaced.
        let exact = apps.filter {
            normalize($0.name) == wanted || normalize($0.url.deletingPathExtension().lastPathComponent) == wanted
        }
        if let resolution = pick(from: exact) { return resolution }

        // 3. A distinctive part of a longer name ("chrome" for "Google Chrome").
        if wanted.count >= 3 {
            let starts = apps.filter { normalize($0.name).hasPrefix(wanted) }
            if let resolution = pick(from: starts) { return resolution }
            let words = apps.filter { name in
                name.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains {
                    normalize(String($0)) == wanted
                }
            }
            if let resolution = pick(from: words) { return resolution }
        }
        // 4. Nothing plausible: offer the nearest names.
        return .notFound(suggestions: nearest(to: wanted, in: apps))
    }

    /// One candidate is a match; several distinct apps are ambiguous. Copies of one app in different folders count as one,
    /// preferring the usual location.
    private static func pick(from candidates: [InstalledApp]) -> Resolution? {
        guard !candidates.isEmpty else { return nil }
        let byName = Dictionary(grouping: candidates) { normalize($0.name) }
        if byName.count == 1 {
            let preferred = candidates.sorted { rank($0) < rank($1) }
            return .found(preferred[0])
        }
        return .ambiguous(candidates.sorted { $0.name < $1.name })
    }

    private static func rank(_ app: InstalledApp) -> Int {
        let path = app.url.path
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix("/System/Applications/") { return 1 }
        return 2
    }

    static func normalize(_ text: String) -> String {
        var value = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        )
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        return value.filter { $0.isLetter || $0.isNumber }
    }

    private static func nearest(to wanted: String, in apps: [InstalledApp]) -> [String] {
        var scored: [(name: String, distance: Int)] = []
        for app in apps {
            let name = normalize(app.name)
            let allowed = max(2, wanted.count / 3)
            let distance = min(editDistance(wanted, name), editDistance(wanted, String(name.prefix(wanted.count))))
            if distance <= allowed { scored.append((app.name, distance)) }
        }
        var seen = Set<String>()
        return
            scored
            .sorted { ($0.distance, $0.name) < ($1.distance, $1.name) }
            .map(\.name)
            .filter { seen.insert($0).inserted }
            .prefix(3)
            .map { $0 }
    }

    /// Levenshtein distance.
    static func editDistance(_ first: String, _ second: String) -> Int {
        let lhs = Array(first)
        let rhs = Array(second)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                current.append(min(previous[column + 1] + 1, current[column] + 1, substitution))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
