import Foundation
import Testing
@testable import VoxaPolicy

/// A throwaway "home folder" and "drives folder", so the rules are exercised on real folders, links and packages without
/// going near the person's own files.
private struct Sandbox {
    let root: URL
    let home: URL
    let volumes: URL
    let policy: FilePathPolicy

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("voxa-paths-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        for folder in [
            "home/Documents/Invoices", "home/Desktop", "home/Downloads", "home/Library/Preferences", "home/.ssh",
            "home/Documents/Notes.app/Contents", "home/Pictures/Holiday.photoslibrary/originals", "home/Documents/project/.git",
            "Volumes/Backup/Photos", "Volumes/Backup/Thing.app/Contents", "elsewhere",
        ] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in [
            "home/Documents/report.pdf", "home/Documents/Invoices/march.pdf", "home/.ssh/id_rsa",
            "home/Library/Preferences/x.plist",
            "home/Documents/Notes.app/Contents/Info.plist", "home/Documents/project/.git/config", "home/Documents/.hidden",
            "Volumes/Backup/Photos/a.jpg", "elsewhere/secret.txt",
        ] {
            manager.createFile(atPath: root.appendingPathComponent(file).path, contents: Data("x".utf8))
        }
        policy = FilePathPolicy(home: home, volumes: volumes)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { home.resolvingSymlinksInPath().appendingPathComponent(relative) }
}

@Suite("FilePathPolicy")
struct FilePathPolicyTests {
    // MARK: Turning text into a location

    @Test("~ is the home folder, and ~/ paths are under it")
    func tilde() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(try box.policy.resolve("~").path == box.policy.home.path)
        #expect(try box.policy.resolve("~/Documents/report.pdf").path == box.policy.home.path + "/Documents/report.pdf")
        #expect(try box.policy.resolve("  ~/Documents/report.pdf \n").lastPathComponent == "report.pdf")
    }

    @Test("dots and doubled slashes are removed, so ../ can't be used to step out")
    func dots() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let escaped = try box.policy.resolve("~/Documents/../../elsewhere/secret.txt")
        #expect(box.policy.modificationProblem(for: escaped) != nil, "stepping out of the home folder must be caught")
        #expect(
            try box.policy.resolve("~/Documents/./Invoices//march.pdf").path == box.policy.home.path
                + "/Documents/Invoices/march.pdf")
    }

    @Test("a path that isn't absolute, or is empty, or has control characters is refused")
    func refused() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(throws: FilePathPolicy.PathError.notAbsolute) { try box.policy.resolve("Documents/report.pdf") }
        #expect(throws: FilePathPolicy.PathError.notAbsolute) { try box.policy.resolve("~alice/x") }
        #expect(throws: FilePathPolicy.PathError.empty) { try box.policy.resolve("   ") }
        #expect(throws: FilePathPolicy.PathError.unreadable) { try box.policy.resolve("/tmp/a\u{0}b") }
        #expect(throws: FilePathPolicy.PathError.unreadable) { try box.policy.resolve("/tmp/a\nb") }
    }

    @Test("a link in the middle of a path is followed, a link at the end is kept as itself")
    func links() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let manager = FileManager.default
        let toElsewhere = box.home.appendingPathComponent("Documents/out")
        try manager.createSymbolicLink(at: toElsewhere, withDestinationURL: box.root.appendingPathComponent("elsewhere"))

        // The link itself is a file in Documents, so it can be moved or trashed as a link...
        let link = try box.policy.resolve("~/Documents/out")
        #expect(link.lastPathComponent == "out")
        #expect(box.policy.modificationProblem(for: link) == nil)
        // ...but reaching *through* it lands outside the home folder, and that is refused.
        let through = try box.policy.resolve("~/Documents/out/secret.txt")
        #expect(through.path.hasSuffix("/elsewhere/secret.txt"))
        #expect(box.policy.modificationProblem(for: through) != nil)
    }

    // MARK: What may be moved or trashed

    @Test("ordinary files and folders in the home folder may be")
    func allowed() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        for path in [
            "Documents/report.pdf", "Documents/Invoices", "Documents/Invoices/march.pdf", "Desktop/new-file.txt",
            "Downloads/x.zip",
        ] {
            #expect(box.policy.modificationProblem(for: box.url(path)) == nil, "\(path)")
        }
    }

    @Test("the home folder and the standard folders themselves may not be")
    func standard() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.policy.modificationProblem(for: box.policy.home)?.contains("home folder") == true)
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications"] {
            #expect(box.policy.modificationProblem(for: box.url(name))?.contains("standard folders") == true, "\(name)")
        }
    }

    @Test("the Library, hidden things, and anything inside a hidden folder may not be")
    func libraryAndHidden() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.policy.modificationProblem(for: box.url("Library"))?.contains("Library") == true)
        #expect(box.policy.modificationProblem(for: box.url("Library/Preferences/x.plist"))?.contains("Library") == true)
        for path in [".ssh", ".ssh/id_rsa", "Documents/.hidden", "Documents/project/.git", "Documents/project/.git/config"] {
            #expect(box.policy.modificationProblem(for: box.url(path))?.contains("hidden") == true, "\(path)")
        }
    }

    @Test("the inside of an app or a library may not be moved, though the whole thing may")
    func packages() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.policy.modificationProblem(for: box.url("Documents/Notes.app")) == nil)
        #expect(
            box.policy.modificationProblem(for: box.url("Documents/Notes.app/Contents/Info.plist"))?.contains("Notes.app") == true
        )
        #expect(box.policy.modificationProblem(for: box.url("Pictures/Holiday.photoslibrary"))?.contains("Holiday") != true)
        #expect(
            box.policy.modificationProblem(for: box.url("Pictures/Holiday.photoslibrary/originals"))?.contains(
                "Holiday.photoslibrary") == true)
    }

    @Test("anything outside the home folder and the drives may not be")
    func outside() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        for path in ["/etc/hosts", "/System/Library", "/Applications/Safari.app", "/usr/bin/ls", "/", "/Users/Shared/x"] {
            #expect(
                box.policy.modificationProblem(for: URL(fileURLWithPath: path))?.contains("isn't in your home folder") == true,
                "\(path)")
        }
        #expect(box.policy.modificationProblem(for: box.root.appendingPathComponent("elsewhere/secret.txt")) != nil)
    }

    @Test("a folder whose name starts like the home folder's is not inside it")
    func lookalike() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let sibling = box.policy.home.deletingLastPathComponent().appendingPathComponent("home-evil/Documents/x.txt")
        #expect(box.policy.modificationProblem(for: sibling)?.contains("isn't in your home folder") == true)
    }

    @Test("files on an external drive may be moved, the drive itself may not, nor the inside of an app on it")
    func drives() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let drive = box.volumes.resolvingSymlinksInPath().appendingPathComponent("Backup")
        #expect(box.policy.modificationProblem(for: drive.appendingPathComponent("Photos/a.jpg")) == nil)
        #expect(box.policy.modificationProblem(for: drive.appendingPathComponent("Photos")) == nil)
        #expect(box.policy.modificationProblem(for: drive)?.contains("whole drive") == true)
        #expect(
            box.policy.modificationProblem(for: drive.appendingPathComponent("Thing.app/Contents"))?.contains("Thing.app") == true
        )
    }

    // MARK: Searching

    @Test("searching is limited to the home folder and the drives")
    func searchScope() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.policy.searchScopeProblem(for: box.policy.home) == nil)
        #expect(box.policy.searchScopeProblem(for: box.url("Documents")) == nil)
        #expect(box.policy.searchScopeProblem(for: box.volumes.resolvingSymlinksInPath().appendingPathComponent("Backup")) == nil)
        #expect(box.policy.searchScopeProblem(for: URL(fileURLWithPath: "/")) != nil)
        #expect(box.policy.searchScopeProblem(for: URL(fileURLWithPath: "/etc")) != nil)
    }

    @Test("a search leaves out hidden things, the Library, and the insides of apps and libraries")
    func searchExclusions() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        for path in [
            "Library/Preferences/x.plist", ".ssh/id_rsa", "Documents/.hidden", "Documents/Notes.app/Contents/Info.plist",
            "Pictures/Holiday.photoslibrary/originals/a.jpg",
        ] {
            #expect(box.policy.isExcludedFromSearch(box.url(path)), "\(path)")
        }
        for path in ["Documents/report.pdf", "Documents/Notes.app", "Pictures/Holiday.photoslibrary", "Desktop/x.txt"] {
            #expect(!box.policy.isExcludedFromSearch(box.url(path)), "\(path)")
        }
    }

    @Test("paths are shown the way a person says them")
    func display() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.policy.display(box.url("Documents/report.pdf")) == "~/Documents/report.pdf")
        #expect(box.policy.display(box.policy.home) == "~")
        #expect(box.policy.display(URL(fileURLWithPath: "/etc/hosts")) == "/etc/hosts")
    }
}
