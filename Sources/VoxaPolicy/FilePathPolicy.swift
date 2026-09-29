import Foundation

/// Which files Voxa will touch, and how a path the model wrote becomes a real one.
///
/// The model names files by path, and a path can be a trap: `~/../../etc`, a symlink that leads out of the home folder, a
/// folder that is really an app. This turns the text into one canonical location first and then applies a few plain rules.
/// Moving or trashing is limited to the user's own files: inside the home folder (leaving out hidden items, the Library,
/// and the standard folders themselves) or on an external drive, and never inside a package such as an app or a photo
/// library, which would break if its contents were shuffled. The person still confirms every move; these rules are what
/// can never be talked into.
public struct FilePathPolicy: Sendable {
    public let home: URL
    public let volumes: URL

    /// - Parameters:
    ///   - home: The folder that counts as the user's own. Tests pass a temporary folder.
    ///   - volumes: Where external drives are mounted.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.volumes = volumes.standardizedFileURL
    }

    public enum PathError: Error, Equatable, Sendable {
        case empty
        case notAbsolute
        case unreadable

        public var explanation: String {
            switch self {
            case .empty: "The path is empty."
            case .notAbsolute: "Use a full path that starts with / or ~."
            case .unreadable: "The path contains characters that can't be part of a file name."
            }
        }
    }

    // MARK: Turning text into a location

    /// The path as a location: `~` expanded, `.` and `..` removed, and the folders leading to it followed through any symlinks.
    /// The last part is kept as written, so a symlink is dealt with as itself rather than as whatever it points at.
    public func resolve(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PathError.empty }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw PathError.unreadable }

        var expanded = text
        if text == "~" {
            expanded = home.path
        } else if text.hasPrefix("~/") {
            expanded = home.path + "/" + text.dropFirst(2)
        }
        guard expanded.hasPrefix("/") else { throw PathError.notAbsolute }

        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if url.path == "/" { return url }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent)
    }

    // MARK: Rules

    /// Why Voxa won't move, rename or trash `url`, in words for the person; nil when it may.
    public func modificationProblem(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if let relative = components(of: path, under: home.path) {
            if relative.isEmpty { return "That is your home folder." }
            if relative.contains(where: { $0.hasPrefix(".") }) {
                return "It is hidden, or inside a hidden folder, where settings and credentials live."
            }
            if relative[0] == "Library" { return "It is in your Library folder, where apps keep their data." }
            if relative.count == 1, Self.standardFolders.contains(relative[0]) {
                return "That is one of your standard folders; only what is inside it can be moved."
            }
            return packageProblem(ancestors: ancestors(of: url, below: home))
        }
        if let relative = components(of: path, under: volumes.path) {
            guard relative.count >= 2 else { return "That is a whole drive." }
            if relative.contains(where: { $0.hasPrefix(".") }) {
                return "It is hidden, or inside a hidden folder."
            }
            let root = volumes.appendingPathComponent(relative[0])
            return packageProblem(ancestors: ancestors(of: url, below: root))
        }
        return "It isn't in your home folder or on an external drive."
    }

    /// Why Voxa won't search in `url`; nil when it may. Searching is limited to the user's own files.
    public func searchScopeProblem(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if components(of: path, under: home.path) != nil { return nil }
        if let relative = components(of: path, under: volumes.path), !relative.isEmpty { return nil }
        return "Voxa only searches your home folder and external drives."
    }

    /// Whether a search should skip `url`: hidden things, the Library, and the insides of apps and libraries, none of which
    /// are files a person means when they ask for one.
    public func isExcludedFromSearch(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var relative = components(of: path, under: home.path) ?? components(of: path, under: volumes.path) ?? []
        if components(of: path, under: home.path) != nil, relative.first == "Library" { return true }
        if relative.contains(where: { $0.hasPrefix(".") }) { return true }
        relative.removeLast(min(1, relative.count))
        return relative.contains { Self.packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// The path the way a person says it: `~/Documents/report.pdf`.
    public func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let relative = components(of: path, under: home.path) {
            return relative.isEmpty ? "~" : "~/" + relative.joined(separator: "/")
        }
        return path
    }

    // MARK: Helpers

    /// The folders of the home directory that hold the user's files and can't themselves be moved away.
    static let standardFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications", "Sites",
    ]

    /// Extensions of folders that are really single things (an app, a photo library) and break if their contents are moved.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "sparsebundle", "sparseimage", "xcodeproj", "xcworkspace", "playground", "rtfd", "logicx",
    ]

    /// The parts of `path` below `root`, or nil when it isn't inside `root` (or is a lookalike such as `/Users/al` and `/Users/alex`).
    private func components(of path: String, under root: String) -> [String]? {
        guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        let rest = path.dropFirst(root.count)
        return rest.split(separator: "/").map(String.init)
    }

    /// The folders between `root` (exclusive) and `url` (exclusive), outermost first.
    private func ancestors(of url: URL, below root: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path.count > root.path.count, current.path.hasPrefix(root.path) {
            result.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    private func packageProblem(ancestors: [URL]) -> String? {
        for folder in ancestors {
            let isPackage = (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            if isPackage || Self.packageExtensions.contains(folder.pathExtension.lowercased()) {
                return "It is inside “\(folder.lastPathComponent)”, which would break if its contents were moved."
            }
        }
        return nil
    }
}
