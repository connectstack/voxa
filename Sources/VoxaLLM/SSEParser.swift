import Foundation

/// Splits a byte stream into lines, keeping **empty** lines (which Foundation's `AsyncBytes.lines` drops, but which are the
/// event delimiters in Server-Sent Events). Handles `\n`, `\r\n` and `\r`, including a `\r\n` split across two chunks. It
/// cuts only at ASCII newline bytes, so a multi-byte UTF-8 character can never be split.
public struct LineSplitter: Sendable {
    private var buffer = Data()
    private var previousWasCarriageReturn = false

    public init() {}

    public mutating func push(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                lines.append(takeLine())
            case 0x0D:
                lines.append(takeLine())
                previousWasCarriageReturn = true
            default:
                buffer.append(byte)
            }
        }
        return lines
    }

    /// The final line if the stream ended without a terminator.
    public mutating func finish() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        // Lossy on purpose: a stray invalid byte in a stream must not throw away the whole line.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: buffer, as: UTF8.self)
    }
}

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// A Server-Sent Events parser following the WHATWG rules: `field: value` lines, `:` comments, multi-line `data`, and a
/// blank line to dispatch. Feed it lines; it returns an event when one completes.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastEventID: String?

    public init() {}

    public mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id" where !value.contains("\0"): lastEventID = String(value)
        default: break  // retry and unknown fields are ignored
        }
        return nil
    }

    /// Delivers a final event that the stream ended without terminating with a blank line.
    public mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }
}
