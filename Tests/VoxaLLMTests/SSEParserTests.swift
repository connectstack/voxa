import Foundation
import Testing
@testable import VoxaLLM

@Suite("LineSplitter")
struct LineSplitterTests {
    @Test("lines are split on LF, CRLF and CR, and empty lines are kept")
    func terminators() {
        var splitter = LineSplitter()
        let lines = splitter.push(Data("a\nb\r\nc\rd\n\ne\n".utf8))
        #expect(lines == ["a", "b", "c", "d", "", "e"])
    }

    @Test("a CRLF split across two chunks is one terminator, not two")
    func splitCRLF() {
        var splitter = LineSplitter()
        var lines = splitter.push(Data("one\r".utf8))
        lines += splitter.push(Data("\ntwo\r\n".utf8))
        #expect(lines == ["one", "two"])
    }

    @Test("a multi-byte character cut in half by a chunk boundary is reassembled")
    func splitUTF8() {
        var splitter = LineSplitter()
        let bytes = Array("caf\u{E9} 😀 ok\n".utf8)
        var lines: [String] = []
        for byte in bytes {  // one byte at a time: the worst case
            lines += splitter.push(Data([byte]))
        }
        #expect(lines == ["café 😀 ok"])
    }

    @Test("a final line without a terminator is returned by finish")
    func unterminated() {
        var splitter = LineSplitter()
        #expect(splitter.push(Data("no newline".utf8)).isEmpty)
        #expect(splitter.finish() == "no newline")
        #expect(splitter.finish() == nil)
    }
}

@Suite("SSEParser")
struct SSEParserTests {
    private func parse(_ text: String) -> [SSEEvent] {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in splitter.push(Data(text.utf8)) {
            if let event = parser.feed(line: line) { events.append(event) }
        }
        if let last = splitter.finish(), let event = parser.feed(line: last) { events.append(event) }
        if let event = parser.finish() { events.append(event) }
        return events
    }

    @Test("an event has a name and data, dispatched by a blank line")
    func basic() {
        let events = parse("event: ping\ndata: {\"type\":\"ping\"}\n\n")
        #expect(events == [SSEEvent(event: "ping", data: #"{"type":"ping"}"#)])
    }

    @Test("several events in one stream")
    func several() {
        let events = parse("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")
        #expect(events.map(\.event) == ["a", "b"])
        #expect(events.map(\.data) == ["1", "2"])
    }

    @Test("multi-line data is joined with newlines")
    func multiLine() {
        #expect(parse("data: line one\ndata: line two\n\n").first?.data == "line one\nline two")
    }

    @Test("comments and unknown fields are ignored; one leading space after the colon is dropped")
    func fields() {
        let events = parse(": keep-alive\nretry: 3000\nfoo: bar\ndata:no-space\ndata:  two-spaces\n\n")
        #expect(events.first?.data == "no-space\n two-spaces")
    }

    @Test("a field with no colon is a field with an empty value")
    func noColon() {
        #expect(parse("data\n\n").first?.data.isEmpty == true)
    }

    @Test("an event with no data is not dispatched")
    func noData() {
        #expect(parse("event: ping\n\n").isEmpty)
    }

    @Test("CRLF streams parse the same as LF streams")
    func crlf() {
        #expect(parse("event: x\r\ndata: y\r\n\r\n") == [SSEEvent(event: "x", data: "y")])
    }

    @Test("a final event without its blank line is still delivered at the end of the stream")
    func unterminatedEvent() {
        #expect(parse("event: last\ndata: tail").first?.data == "tail")
    }

    @Test("the event name does not leak into the next event")
    func nameResets() {
        let events = parse("event: first\ndata: 1\n\ndata: 2\n\n")
        #expect(events.map(\.event) == ["first", nil])
    }

    @Test("data containing colons and JSON survives intact")
    func colonsInData() {
        let json = #"{"a":"b: c","url":"https://x.test/y?z=1"}"#
        #expect(parse("data: \(json)\n\n").first?.data == json)
    }
}
