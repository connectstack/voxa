import Foundation
import Testing
@testable import VoxaSpeech

@Suite("TranscriptAssembler")
struct TranscriptAssemblerTests {
    @Test("a volatile guess is replaced by the next volatile guess")
    func volatileReplaced() {
        var assembler = TranscriptAssembler()
        #expect(assembler.apply(text: "open", isFinal: false) == "open")
        #expect(assembler.apply(text: "open Safari", isFinal: false) == "open Safari")
        #expect(assembler.apply(text: "opens a fairy", isFinal: false) == "opens a fairy")
    }

    @Test("finalized segments accumulate and later guesses append to them")
    func finalizedAccumulates() {
        var assembler = TranscriptAssembler()
        assembler.apply(text: "Set a timer", isFinal: false)
        let first = "Set a timer for five minutes."
        #expect(assembler.apply(text: first, isFinal: true) == first)
        #expect(assembler.apply(text: "and remind me", isFinal: false) == "\(first) and remind me")
        #expect(assembler.apply(text: "and remind me to stretch.", isFinal: true) == "\(first) and remind me to stretch.")
    }

    @Test("a final result clears the pending volatile guess")
    func finalClearsVolatile() {
        var assembler = TranscriptAssembler()
        assembler.apply(text: "hello wor", isFinal: false)
        assembler.apply(text: "hello world", isFinal: true)
        #expect(assembler.volatile.isEmpty)
        #expect(assembler.current == "hello world")
    }

    @Test("input that ends while a guess is pending promotes it to final text")
    func pendingPromoted() {
        var assembler = TranscriptAssembler()
        assembler.apply(text: "Call mom.", isFinal: true)
        assembler.apply(text: "tomorrow at noon", isFinal: false)
        #expect(assembler.finalText == "Call mom. tomorrow at noon")
    }

    @Test("empty and whitespace-only results add nothing")
    func emptyResults() {
        var assembler = TranscriptAssembler()
        assembler.apply(text: "   ", isFinal: true)
        assembler.apply(text: "", isFinal: false)
        #expect(assembler.current.isEmpty)
        #expect(assembler.finalized.isEmpty)
    }

    @Test("surrounding whitespace is trimmed so segments join cleanly")
    func trimming() {
        var assembler = TranscriptAssembler()
        assembler.apply(text: "  first ", isFinal: true)
        assembler.apply(text: " second\n", isFinal: true)
        #expect(assembler.current == "first second")
    }

    @Test("languages written without spaces join segments directly")
    func unspacedLanguages() {
        var japanese = TranscriptAssembler(locale: Locale(identifier: "ja_JP"))
        japanese.apply(text: "今日は", isFinal: true)
        japanese.apply(text: "晴れです", isFinal: true)
        #expect(japanese.current == "今日は晴れです")

        var english = TranscriptAssembler(locale: Locale(identifier: "en_US"))
        english.apply(text: "good", isFinal: true)
        english.apply(text: "morning", isFinal: true)
        #expect(english.current == "good morning")
    }
}
