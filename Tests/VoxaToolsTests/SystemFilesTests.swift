import Foundation
import Testing
import VoxaPolicy
@testable import VoxaTools

/// A throwaway home folder on the real disk, so the real file code is exercised on real files without going near anyone's own.
private struct Tree {
    let root: URL
    let policy: FilePathPolicy
    let files: SystemFiles

    init(searcher: any FileSearching = DirectorySearch()) throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("voxa-files-\(UUID().uuidString)", isDirectory: true)
        for folder in [
            "Documents/Invoices", "Documents/Notes.app/Contents/Resources", "Desktop", "Downloads", "Library/Caches", ".hidden",
            "Documents/Taxes",
        ] {
            try manager.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let now = Date()
        func file(_ path: String, daysAgo: Double = 1, bytes: Int = 10) throws {
            let url = base.appendingPathComponent(path)
            manager.createFile(atPath: url.path, contents: Data(repeating: 65, count: bytes))
            try manager.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
        try file("Documents/Invoices/march-invoice.pdf", daysAgo: 30)
        try file("Documents/Invoices/april-invoice.pdf", daysAgo: 3)
        try file("Documents/report.docx", daysAgo: 9)
        try file("Documents/Résumé.pdf", daysAgo: 100)
        try file("Documents/Notes.app/Contents/Resources/invoice-template.pdf")
        try file("Desktop/Screenshot 1.png", daysAgo: 0.5, bytes: 500)
        try file("Desktop/Screenshot 2.png", daysAgo: 0.2, bytes: 800)
        try file("Downloads/report.pdf", daysAgo: 1)
        try file("Library/Caches/invoice-cache.pdf")
        try file(".hidden/invoice-secret.pdf")
        let policy = FilePathPolicy(home: base, volumes: base.appendingPathComponent("Volumes"))
        self.root = base
        self.policy = policy
        self.files = SystemFiles(policy: policy, searcher: searcher)
    }

    func cleanUp() {
        // Put permissions back so a test that made something read-only doesn't leave a folder that can't be removed.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    var home: URL { policy.home }
    func url(_ path: String) -> URL { home.appendingPathComponent(path) }
    func query(_ words: [String], kind: FileKind? = nil, since: Date? = nil, limit: Int = 20) -> FileQuery {
        FileQuery(words: words, folders: [home], kind: kind, modifiedAfter: since, limit: limit)
    }
    func names(_ result: FileSearchResult) -> [String] { result.matches.map { ($0.path as NSString).lastPathComponent } }
}

@Suite("Searching folders")
struct DirectorySearchTests {
    @Test("names are matched by every word, ignoring case and accents, newest first")
    func matches() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        // The folder was made just now, so it is newest; then April's invoice, then March's.
        let found = try await tree.files.search(tree.query(["invoice"]))
        #expect(tree.names(found) == ["Invoices", "april-invoice.pdf", "march-invoice.pdf"])
        #expect(tree.names(try await tree.files.search(tree.query(["RESUME"]))) == ["Résumé.pdf"])
        #expect(tree.names(try await tree.files.search(tree.query(["screenshot", "2"]))) == ["Screenshot 2.png"])
        #expect(try await tree.files.search(tree.query(["nothing-like-this"])).matches.isEmpty)
    }

    @Test("the Library, hidden folders and the inside of an app are left out; the app itself is found")
    func exclusions() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let invoices = tree.names(try await tree.files.search(tree.query(["invoice"])))
        #expect(
            !invoices.contains("invoice-cache.pdf") && !invoices.contains("invoice-secret.pdf")
                && !invoices.contains("invoice-template.pdf"))
        #expect(tree.names(try await tree.files.search(tree.query(["notes"]))) == ["Notes.app"])
    }

    @Test("a kind of file narrows the search")
    func kinds() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        #expect(
            tree.names(try await tree.files.search(tree.query(["invoice"], kind: .pdf))) == [
                "april-invoice.pdf", "march-invoice.pdf",
            ])
        #expect(
            tree.names(try await tree.files.search(tree.query(["screenshot"], kind: .image))) == [
                "Screenshot 2.png", "Screenshot 1.png",
            ])
        #expect(tree.names(try await tree.files.search(tree.query(["invoice"], kind: .folder))) == ["Invoices"])
        #expect(try await tree.files.search(tree.query(["screenshot"], kind: .pdf)).matches.isEmpty)
    }

    @Test("a Word file and a PDF are both documents, but only one of them is a PDF")
    func documents() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        // The PDF is newer (a day old; the Word file is nine).
        #expect(
            tree.names(try await tree.files.search(tree.query(["report"], kind: .document))) == ["report.pdf", "report.docx"])
        #expect(tree.names(try await tree.files.search(tree.query(["report"], kind: .pdf))) == ["report.pdf"])
    }

    @Test("how recently a file changed narrows the search")
    func recency() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let week = Date().addingTimeInterval(-7 * 86_400)
        let names = tree.names(try await tree.files.search(tree.query(["invoice"], kind: .pdf, since: week)))
        #expect(names == ["april-invoice.pdf"])
    }

    @Test("results are cut to the limit, and the result says there were more")
    func limit() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let result = try await tree.files.search(tree.query(["screenshot"], limit: 1))
        #expect(result.matches.count == 1 && result.isCutShort)
        #expect(result.matches[0].path.hasSuffix("Screenshot 2.png"), "the newer one is kept")
        #expect(try await tree.files.search(tree.query(["screenshot"], limit: 5)).isCutShort == false)
    }

    @Test("a search that would look at too much stops, and says it stopped")
    func budget() async throws {
        let tree = try Tree(searcher: DirectorySearch(maxVisited: 3))
        defer { tree.cleanUp() }
        let result = try await tree.files.search(tree.query(["pdf"]))
        #expect(result.isCutShort)
    }

    @Test("a cancelled command stops the search")
    func cancelled() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let task = Task { () -> FileSearchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tree.files.search(tree.query(["invoice"]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("what each result says about the file is what the disk says")
    func details() async throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let match = try #require(try await tree.files.search(tree.query(["screenshot", "2"])).matches.first)
        #expect(match.size == 800 && !match.isDirectory && !match.kind.isEmpty)
        #expect(
            match.modified.map { Date().timeIntervalSince($0) > 0.19 * 86_400 && Date().timeIntervalSince($0) < 0.21 * 86_400 }
                == true)
    }
}

@Suite("Spotlight")
struct SpotlightTests {
    @Test("every word must be in the name, matched without regard to case or accents")
    func words() {
        let query = FileQuery(words: ["tax", "invoice"], folders: [])
        #expect(
            SpotlightSearch.predicate(for: query) == #"kMDItemDisplayName == "*tax*"cd && kMDItemDisplayName == "*invoice*"cd"#)
    }

    @Test("a kind becomes the types that count as it, and recency becomes a time relative to now")
    func kindAndDate() {
        var query = FileQuery(words: ["a"], folders: [], kind: .image)
        #expect(SpotlightSearch.predicate(for: query).hasSuffix(#"(kMDItemContentTypeTree == "public.image")"#))
        query.kind = .document
        #expect(
            SpotlightSearch.predicate(for: query).contains(
                #"(kMDItemContentTypeTree == "public.composite-content" || kMDItemContentTypeTree == "public.text")"#))
        query.kind = nil
        query.modifiedAfter = Date().addingTimeInterval(-3 * 86_400)
        let predicate = SpotlightSearch.predicate(for: query)
        let seconds = try? #require(Int(predicate.components(separatedBy: "$time.now(-").last?.dropLast() ?? ""))
        #expect(seconds.map { abs($0 - 3 * 86_400) < 5 } == true, "\(predicate)")
    }

    @Test("words that could be syntax never reach the query: they were reduced to safe characters first")
    func noInjection() {
        let words = FileQuery.words(from: #"x" || kMDItemDisplayName == "*"#)
        let predicate = SpotlightSearch.predicate(for: FileQuery(words: words, folders: []))
        #expect(!predicate.contains("||") && !predicate.contains("==" + "\"*\""))
        #expect(predicate.filter { $0 == "\"" }.count == words.count * 2, "one pair of quotes per word, none from the text")
    }

    /// An index that is turned off, or a machine that isn't answering, sends the search to the folders instead.
    private struct Unavailable: FileSearching {
        func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult {
            throw FileSearchError.spotlightUnavailable
        }
    }

    private struct Broken: FileSearching {
        struct Failure: Error {}
        func search(_ query: FileQuery, policy: FilePathPolicy) async throws -> FileSearchResult { throw Failure() }
    }

    @Test("when Spotlight isn't available the folders are searched; any other failure is not hidden")
    func fallback() async throws {
        let tree = try Tree(searcher: FallbackFileSearch(primary: Unavailable(), fallback: DirectorySearch()))
        defer { tree.cleanUp() }
        #expect(tree.names(try await tree.files.search(tree.query(["screenshot", "1"]))) == ["Screenshot 1.png"])

        let broken = FallbackFileSearch(primary: Broken(), fallback: DirectorySearch())
        await #expect(throws: Broken.Failure.self) { try await broken.search(tree.query(["x"]), policy: tree.policy) }
    }

    @Test(
        "the real index answers, and a nonsense word finds nothing",
        .enabled(if: FileManager.default.fileExists(atPath: "/System/Library/CoreServices/Spotlight.app")))
    func live() async throws {
        let query = FileQuery(words: ["zzqvxw\(UUID().uuidString.prefix(8).lowercased())"], folders: [FilePathPolicy().home])
        do {
            let result = try await SpotlightSearch().search(query, policy: FilePathPolicy())
            #expect(result.matches.isEmpty)
        } catch FileSearchError.spotlightUnavailable {
            // Spotlight is switched off on this machine, which is exactly the case the fallback is for.
        }
    }
}

@Suite("Real file changes")
struct SystemFilesTests {
    @Test("a file, a folder, a link to a folder, a link to nowhere, and nothing are told apart")
    func status() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let manager = FileManager.default
        try manager.createSymbolicLink(at: tree.url("Documents/link"), withDestinationURL: tree.url("Desktop"))
        try manager.createSymbolicLink(at: tree.url("Documents/dangling"), withDestinationURL: tree.url("nowhere"))

        let file = tree.files.status(of: tree.url("Desktop/Screenshot 2.png"))
        #expect(file.exists && !file.isDirectory && !file.isSymbolicLink && file.size == 800 && !file.kind.isEmpty)
        let folder = tree.files.status(of: tree.url("Desktop"))
        #expect(folder.exists && folder.isDirectory && folder.size == nil)
        let link = tree.files.status(of: tree.url("Documents/link"))
        #expect(
            link.exists && link.isDirectory && link.isSymbolicLink, "a link to a folder counts as a folder to move things into")
        let dangling = tree.files.status(of: tree.url("Documents/dangling"))
        #expect(dangling.exists && !dangling.isDirectory && dangling.isSymbolicLink)
        #expect(tree.files.status(of: tree.url("Desktop/nope")) == .missing)
    }

    @Test("moving puts the file at the new place, keeping what is in it")
    func moves() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.files.move(from: tree.url("Downloads/report.pdf"), to: tree.url("Documents/Taxes/report.pdf"))
        #expect(!FileManager.default.fileExists(atPath: tree.url("Downloads/report.pdf").path))
        #expect(try Data(contentsOf: tree.url("Documents/Taxes/report.pdf")) == Data(repeating: 65, count: 10))
        // A whole folder goes with what is in it.
        try tree.files.move(from: tree.url("Documents/Invoices"), to: tree.url("Documents/Taxes/Invoices"))
        #expect(FileManager.default.fileExists(atPath: tree.url("Documents/Taxes/Invoices/march-invoice.pdf").path))
    }

    @Test("moving never replaces: an existing destination is refused and both files are as they were")
    func noOverwrite() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        #expect(throws: FileError.alreadyExists) {
            try tree.files.move(from: tree.url("Downloads/report.pdf"), to: tree.url("Documents/report.docx"))
        }
        #expect(FileManager.default.fileExists(atPath: tree.url("Downloads/report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: tree.url("Documents/report.docx").path))
    }

    @Test("problems are named by what a person can do about them")
    func errors() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        #expect(throws: FileError.notFound) {
            try tree.files.move(from: tree.url("Desktop/missing"), to: tree.url("Desktop/elsewhere"))
        }
        #expect(throws: FileError.notFound) { _ = try tree.files.trash(tree.url("Desktop/missing")) }
        #expect(throws: FileError.notFound) {
            try tree.files.move(from: tree.url("Downloads/report.pdf"), to: tree.url("Nowhere/at/all/report.pdf"))
        }

        // A folder that can't be written to.
        let locked = tree.url("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("a.txt").path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        #expect(throws: FileError.notPermitted) {
            try tree.files.move(from: locked.appendingPathComponent("a.txt"), to: tree.url("Desktop/a.txt"))
        }
    }

    @Test("a folder is made only where the folder above it exists, and never over something")
    func folders() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.files.createFolder(at: tree.url("Desktop/Screenshots"))
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: tree.url("Desktop/Screenshots").path, isDirectory: &isDirectory)
                && isDirectory.boolValue)
        #expect(throws: FileError.alreadyExists) { try tree.files.createFolder(at: tree.url("Desktop/Screenshots")) }
        #expect(throws: FileError.notFound) { try tree.files.createFolder(at: tree.url("Desktop/a/b/c")) }
    }

    @Test("the errors that quote file names are reported by number instead")
    func numbers() {
        let odd = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [NSLocalizedDescriptionKey: "“secret.pdf” could not be saved"]
        )
        #expect(SystemFiles.map(odd) == .failed(code: NSFileWriteOutOfSpaceError))
        #expect(!SystemFiles.map(odd).message.contains("secret"))
        #expect(SystemFiles.map(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .notPermitted)
        #expect(SystemFiles.map(NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))) == .alreadyExists)
        #expect(SystemFiles.map(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) == .notFound)
    }
}
