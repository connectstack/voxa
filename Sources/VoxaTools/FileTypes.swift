import Foundation
import VoxaPolicy

/// A kind of file a search can be narrowed to.
public enum FileKind: String, CaseIterable, Sendable {
    case document, pdf, image, audio, video, folder, archive, spreadsheet, presentation, code, app

    /// The type identifiers (Uniform Type Identifiers) that count as this kind.
    var typeIdentifiers: [String] {
        switch self {
        case .document: ["public.composite-content", "public.text"]
        case .pdf: ["com.adobe.pdf"]
        case .image: ["public.image"]
        case .audio: ["public.audio"]
        case .video: ["public.movie"]
        case .folder: ["public.folder"]
        case .archive: ["public.archive"]
        case .spreadsheet: ["public.spreadsheet"]
        case .presentation: ["public.presentation"]
        case .code: ["public.source-code"]
        case .app: ["com.apple.application"]
        }
    }
}

/// What to look for, and where.
public struct FileQuery: Sendable, Equatable {
    /// Words that must all appear in the file's name, in any order.
    public var words: [String]
    public var folders: [URL]
    public var kind: FileKind?
    public var modifiedAfter: Date?
    public var limit: Int

    public init(words: [String], folders: [URL], kind: FileKind? = nil, modifiedAfter: Date? = nil, limit: Int = 20) {
        self.words = words
        self.folders = folders
        self.kind = kind
        self.modifiedAfter = modifiedAfter
        self.limit = limit
    }
}

public struct FileMatch: Sendable, Equatable {
    public var path: String
    /// What Finder calls it: "PDF document", "Folder".
    public var kind: String
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool

    public init(path: String, kind: String, size: Int64? = nil, modified: Date? = nil, isDirectory: Bool = false) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

public struct FileSearchResult: Sendable, Equatable {
    public var matches: [FileMatch]
    /// Whether there were more matches than were kept, or the search had to stop before it had looked everywhere.
    public var isCutShort: Bool

    public init(matches: [FileMatch], isCutShort: Bool = false) {
        self.matches = matches
        self.isCutShort = isCutShort
    }
}

/// What is known about one path, cheaply, without reading the file.
public struct FileStatus: Sendable, Equatable {
    public var exists: Bool
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var kind: String
    public var size: Int64?

    public init(exists: Bool, isDirectory: Bool = false, isSymbolicLink: Bool = false, kind: String = "", size: Int64? = nil) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.kind = kind
        self.size = size
    }

    public static let missing = FileStatus(exists: false)
}

public enum FileError: Error, Equatable, Sendable {
    case notFound
    case alreadyExists
    /// macOS didn't let Voxa do it: a folder Voxa hasn't been given access to, or a file that is locked.
    case notPermitted
    case failed(code: Int)

    /// For the model: what happened, without any file names.
    public var message: String {
        switch self {
        case .notFound: "it no longer exists"
        case .alreadyExists: "something with that name is already there"
        case .notPermitted:
            "macOS didn't allow it (the folder may need to be allowed in System Settings → Privacy & Security → Files and Folders)"
        case .failed(let code): "the system reported an error (\(code))"
        }
    }
}

/// The user's files, behind a protocol so the tools are tested against a pretend disk. The real one moves real files, and is
/// only ever asked to do what the policy and the confirmation have already allowed.
public protocol FileAccessing: Sendable {
    /// Which files Voxa may search in and change. The real one is about the user's home folder.
    var policy: FilePathPolicy { get }

    func status(of url: URL) -> FileStatus
    func search(_ query: FileQuery) async throws -> FileSearchResult
    /// Moves `source` to `destination`, which must not exist: nothing is ever replaced.
    func move(from source: URL, to destination: URL) throws
    /// Makes a folder whose parent already exists.
    func createFolder(at url: URL) throws
    /// Moves an item to the Trash and returns where it went. Nothing is ever deleted outright.
    func trash(_ url: URL) throws -> URL
    /// Shows the item in a Finder window, selected.
    func reveal(_ url: URL) async throws
}
