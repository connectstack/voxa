import CoreServices
import Foundation
import UniformTypeIdentifiers
import VoxaPolicy

/// Something that can look for files by name.
public protocol FileSearching: Sendable {
    func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult
}

public enum FileSearchError: Error, Equatable, Sendable {
    /// Spotlight couldn't be used (switched off, or not answering), so the caller should look some other way.
    case spotlightUnavailable
}

extension FileSearchResult {
    /// Newest first, cut to the limit, leaving out what a search never means to find (see `FilePathPolicy.isExcludedFromSearch`).
    static func finished(_ matches: [FileMatch], query: FileQuery, policy: FilePathPolicy, alreadyCutShort: Bool) -> FileSearchResult {
        let wanted = matches.filter { !policy.isExcludedFromSearch(URL(fileURLWithPath: $0.path)) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return FileSearchResult(matches: Array(wanted.prefix(query.limit)), isCutShort: alreadyCutShort || wanted.count > query.limit)
    }
}

// MARK: - Spotlight

/// Spotlight's index, which finds a file in the whole home folder in a blink. The question is built from the search words
/// after they have been reduced to letters and digits, so nothing the model wrote can act as query syntax.
public struct SpotlightSearch: FileSearching {
    /// Spotlight is asked for more than the limit, because the results are then filtered and sorted here.
    static let rawLimit = 1_000

    public init() {}

    /// The Spotlight query for `query`: every word in the name, the kind, and how recently it changed.
    static func predicate(for query: FileQuery) -> String {
        var clauses = query.words.map { "kMDItemDisplayName == \"*\($0)*\"cd" }
        if let kind = query.kind {
            clauses.append("(" + kind.typeIdentifiers.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
        }
        if let since = query.modifiedAfter {
            clauses.append("kMDItemFSContentChangeDate >= $time.now(\(-Int(max(0, Date().timeIntervalSince(since)))))")
        }
        return clauses.joined(separator: " && ")
    }

    public func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult {
        let predicate = Self.predicate(for: query)
        let folders = query.folders.map(\.path)
        // The question is answered on the calling thread, so it is asked from a thread of its own.
        let raw = try await Task.detached(priority: .userInitiated) { try Self.run(predicate, in: folders) }.value
        return .finished(raw.matches, query: query, policy: policy, alreadyCutShort: raw.cut)
    }

    private static func run(_ predicate: String, in folders: [String]) throws -> (matches: [FileMatch], cut: Bool) {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else {
            throw FileSearchError.spotlightUnavailable
        }
        MDQuerySetSearchScope(mdQuery, folders as CFArray, 0)
        MDQuerySetMaxCount(mdQuery, rawLimit)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { throw FileSearchError.spotlightUnavailable }

        let count = MDQueryGetResultCount(mdQuery)
        var matches: [FileMatch] = []
        for index in 0..<count {
            guard let pointer = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let type = MDItemCopyAttribute(item, kMDItemContentType) as? String
            matches.append(
                FileMatch(
                    path: path,
                    kind: (MDItemCopyAttribute(item, kMDItemKind) as? String) ?? "Document",
                    size: (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.int64Value,
                    modified: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date,
                    isDirectory: type == UTType.folder.identifier
                )
            )
        }
        return (matches, count >= rawLimit)
    }
}

// MARK: - Looking through folders

/// Looks through the folders one by one. Slower than Spotlight and bounded in time and effort, but it needs no index, so it
/// answers when Spotlight can't, and it is what the tests exercise.
public struct DirectorySearch: FileSearching {
    private let maxVisited: Int
    private let timeBudget: Duration

    public init(maxVisited: Int = 40_000, timeBudget: Duration = .seconds(5)) {
        self.maxVisited = maxVisited
        self.timeBudget = timeBudget
    }

    public func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult {
        try walk(query, policy: policy)
    }

    /// Synchronous, because a directory enumerator can't be iterated from asynchronous code. It checks for cancellation as it goes.
    private func walk(_ query: FileQuery, policy: FilePathPolicy) throws -> FileSearchResult {
        let deadline = ContinuousClock.now.advanced(by: timeBudget)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .contentTypeKey,
        ]
        var matches: [FileMatch] = []
        var visited = 0
        var cut = false

        for folder in query.folders {
            guard let walker = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                visited += 1
                if visited > maxVisited || ContinuousClock.now > deadline {
                    cut = true
                    break
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if policy.isExcludedFromSearch(url) {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                if let match = Self.match(url, values: values, query: query) { matches.append(match) }
            }
            if cut { break }
        }
        return .finished(matches, query: query, policy: policy, alreadyCutShort: cut)
    }

    private static func match(_ url: URL, values: URLResourceValues?, query: FileQuery) -> FileMatch? {
        let name = url.lastPathComponent
        for word in query.words where name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
        let isDirectory = values?.isDirectory == true && values?.isPackage != true
        if let kind = query.kind, !isOfKind(kind, values: values, isDirectory: isDirectory) { return nil }
        if let since = query.modifiedAfter, (values?.contentModificationDate ?? .distantPast) < since { return nil }
        return FileMatch(
            path: url.path,
            kind: values?.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            isDirectory: isDirectory
        )
    }

    private static func isOfKind(_ kind: FileKind, values: URLResourceValues?, isDirectory: Bool) -> Bool {
        if kind == .folder { return isDirectory }
        guard let type = values?.contentType else { return false }
        return kind.typeIdentifiers.contains { UTType($0).map(type.conforms(to:)) ?? false }
    }
}

// MARK: - Both

/// Spotlight when it works; looking through the folders when it doesn't.
public struct FallbackFileSearch: FileSearching {
    private let primary: any FileSearching
    private let fallback: any FileSearching

    public init(primary: any FileSearching = SpotlightSearch(), fallback: any FileSearching = DirectorySearch()) {
        self.primary = primary
        self.fallback = fallback
    }

    public func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult {
        do {
            return try await primary.search(query, policy: policy)
        } catch FileSearchError.spotlightUnavailable {
            return try await fallback.search(query, policy: policy)
        }
    }
}
