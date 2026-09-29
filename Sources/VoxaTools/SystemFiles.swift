import AppKit
import Foundation
import VoxaPolicy

/// The user's real files.
///
/// It does what it is told and nothing more: the tools have already checked the paths against the policy and the person has
/// already approved the change. Moving never replaces (`moveItem` refuses an existing destination), and there is no way to
/// delete: the only thing that gets rid of a file is the Trash.
public struct SystemFiles: FileAccessing {
    public let policy: FilePathPolicy
    private let searcher: any FileSearching

    public init(policy: FilePathPolicy = FilePathPolicy(), searcher: any FileSearching = FallbackFileSearch()) {
        self.policy = policy
        self.searcher = searcher
    }

    public func status(of url: URL) -> FileStatus {
        // Asked about the link itself, so a link to nowhere still exists as a link.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        let isLink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [
            .isDirectoryKey, .localizedTypeDescriptionKey, .fileSizeKey,
        ])
        let isDirectory = values?.isDirectory == true
        return FileStatus(
            exists: true,
            isDirectory: isDirectory,
            isSymbolicLink: isLink,
            kind: values?.localizedTypeDescription ?? "",
            size: isDirectory ? nil : values?.fileSize.map(Int64.init)
        )
    }

    public func search(_ query: FileQuery) async throws -> FileSearchResult {
        try await searcher.search(query, policy: policy)
    }

    public func move(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw Self.map(error)
        }
    }

    public func createFolder(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw Self.map(error)
        }
    }

    public func trash(_ url: URL) throws -> URL {
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return (trashed as URL?) ?? url
        } catch {
            throw Self.map(error)
        }
    }

    public func reveal(_ url: URL) async throws {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// The reasons a person can do something about, in plain terms; anything else is reported by its error number, since the
    /// system's own wording can quote file names.
    static func map(_ error: any Error) -> FileError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
            case NSFileWriteFileExistsError: return .alreadyExists
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .notPermitted
            default: break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return posix(underlying.code) ?? .failed(code: nsError.code)
            }
        }
        if nsError.domain == NSPOSIXErrorDomain { return posix(nsError.code) ?? .failed(code: nsError.code) }
        return .failed(code: nsError.code)
    }

    private static func posix(_ code: Int) -> FileError? {
        switch Int32(code) {
        case ENOENT: .notFound
        case EEXIST, ENOTEMPTY: .alreadyExists
        case EPERM, EACCES: .notPermitted
        default: nil
        }
    }
}
