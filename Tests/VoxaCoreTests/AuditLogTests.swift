import Foundation
import Testing
@testable import VoxaCore

@Suite("JSONLAuditLog")
struct AuditLogTests {
    private func makeLog(maxBytes: Int = 5 * 1_024 * 1_024) -> (JSONLAuditLog, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-audit-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("audit.jsonl")
        return (JSONLAuditLog(url: url, maxBytes: maxBytes), directory)
    }

    private func entry(_ kind: AuditEntry.Kind = .command, detail: String? = nil, run: UUID = UUID()) -> AuditEntry {
        AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            runID: run,
            kind: kind,
            tool: "open_app",
            risk: .reversible,
            outcome: "ok",
            detail: detail
        )
    }

    @Test("entries are appended as one JSON object per line, in order, and read back")
    func appendAndRead() async throws {
        let (log, directory) = makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = UUID()
        await log.record(entry(.command, detail: "open safari", run: run))
        await log.record(entry(.toolResult, run: run))

        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["runID"] as? String == run.uuidString)
        }
        let entries = await log.entries()
        #expect(entries.map(\.kind) == [.command, .toolResult])
        #expect(entries.first?.detail == "open safari")
        #expect(entries.first?.risk == .reversible)
    }

    @Test("the file and its folder are private to the user")
    func permissions() async throws {
        let (log, directory) = makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await log.record(entry())
        let file = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(folder == 0o700)
    }

    @Test("a line that can't be read is skipped and doesn't hide the rest")
    func corruptLine() async throws {
        let (log, directory) = makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await log.record(entry(.command))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this is not json\n".utf8))
        try handle.close()
        await log.record(entry(.reply))
        #expect(await log.entries().map(\.kind) == [.command, .reply])
    }

    @Test("past its size limit the file is moved aside once, and only one old file is kept")
    func rotation() async throws {
        let (log, directory) = makeLog(maxBytes: 600)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<12 {
            await log.record(entry(.command, detail: String(repeating: "x", count: 100) + "\(index)"))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["audit.1.jsonl", "audit.jsonl"])
        let current = try Data(contentsOf: log.url).count
        #expect(current <= 600 + 400, "the current file starts over after rotation; got \(current) bytes")
    }

    @Test("clearing removes the log and the rotated copy, and logging can continue")
    func clear() async throws {
        let (log, directory) = makeLog(maxBytes: 300)
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<6 { await log.record(entry(.command, detail: String(repeating: "y", count: 120))) }
        try await log.clear()
        #expect(await log.entries().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        await log.record(entry(.reply))
        #expect(await log.entries().map(\.kind) == [.reply])
    }

    @Test("reading a log that doesn't exist yet gives no entries, and a discarding log never fails")
    func empty() async {
        let (log, _) = makeLog()
        #expect(await log.entries().isEmpty)
        await DiscardingAuditLog().record(entry())
    }

    @Test("an unwritable location is logged and swallowed, never thrown into the agent")
    func unwritable() async {
        let log = JSONLAuditLog(url: URL(fileURLWithPath: "/dev/null/nope/audit.jsonl"))
        await log.record(entry())
        #expect(await log.entries().isEmpty)
    }
}
