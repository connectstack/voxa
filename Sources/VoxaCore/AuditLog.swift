import Foundation

/// The on-disk audit trail: one JSON object per line, append-only, readable with `grep` and `jq`.
///
/// It records what the user asked and what Voxa did about it (which tools, the policy's decision, the user's answer, the
/// outcome). It does **not** record tool output, and it never holds the API key. The file is private to the user
/// (mode 0600). It is capped: past `maxBytes` the current file is moved aside once (`audit.1.jsonl`, replacing an older
/// one), so it can't grow without bound.
///
/// A failure to write is logged and swallowed: a broken log must not stop the agent, but it must not be silent either.
public actor JSONLAuditLog: AuditLogging, AuditReading {
    public nonisolated let url: URL
    private let maxBytes: Int
    private let encoder: JSONEncoder
    private var handle: FileHandle?

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxa", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    public init(url: URL = JSONLAuditLog.defaultURL, maxBytes: Int = 5 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func record(_ entry: AuditEntry) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let handle = try openHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try rotateIfNeeded()
        } catch {
            Log.app.error("could not write the audit log: \(error.localizedDescription, privacy: .public)")
            handle = nil
        }
    }

    /// Every entry, oldest first, including the ones that were moved aside when the file grew. Lines that can't be read are
    /// skipped, so one bad line never hides the rest.
    public func entries() -> [AuditEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return [rotatedURL, url].flatMap { file -> [AuditEntry] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditEntry.self, from: Data($0)) }
        }
    }

    public func readAll() -> [AuditEntry] { entries() }

    /// How much room the trail takes on disk, both files together.
    public func sizeOnDisk() -> Int {
        [rotatedURL, url].reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            return total + (size ?? 0)
        }
    }

    public nonisolated var location: URL? { url }

    /// Deletes the log. The only way entries are ever removed, and only on the user's request.
    public func clear() throws {
        try? handle?.close()
        handle = nil
        for candidate in [url, rotatedURL] where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private var rotatedURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("audit.1.jsonl")
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: url)
        handle = opened
        return opened
    }

    private func rotateIfNeeded() throws {
        guard let handle, try handle.offset() > UInt64(maxBytes) else { return }
        try handle.close()
        self.handle = nil
        if FileManager.default.fileExists(atPath: rotatedURL.path) { try FileManager.default.removeItem(at: rotatedURL) }
        try FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
