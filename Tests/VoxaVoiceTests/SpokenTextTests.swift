import Testing
@testable import VoxaVoice

@Suite("SpokenText")
struct SpokenTextTests {
    @Test("a plain sentence is left as it is")
    func plain() {
        #expect(SpokenText.prepare("I opened Safari.") == "I opened Safari.")
    }

    @Test("a web address is not read out letter by letter")
    func urls() {
        #expect(SpokenText.prepare("I opened https://example.com/a?b=1 for you.") == "I opened a link for you.")
        #expect(SpokenText.prepare("See http://x.test.") == "See a link")
    }

    @Test("markdown the model wasn't supposed to write isn't spoken as punctuation")
    func markdown() {
        #expect(SpokenText.prepare("**Done.** I added *two* events.") == "Done. I added two events.")
        #expect(SpokenText.prepare("Run `ls` now") == "Run ls now")
        #expect(SpokenText.prepare("# Result\nAll good") == "Result. All good")
        #expect(SpokenText.prepare("[the docs](https://example.com) explain it") == "the docs explain it")
        #expect(SpokenText.prepare("Here:\n```\nrm -rf x\n```\nDone.") == "Here: Done.")
    }

    @Test("a list becomes sentences, without the bullets")
    func lists() {
        #expect(SpokenText.prepare("You have:\n- Dentist at 3\n- Standup at 10") == "You have: Dentist at 3. Standup at 10")
    }

    @Test("line breaks and runs of spaces become single spaces")
    func whitespace() {
        #expect(SpokenText.prepare("  Hello   there \n\n  friend. ") == "Hello there. friend.")
        #expect(SpokenText.prepare("First.\nSecond.") == "First. Second.")
    }

    @Test("an empty or blank reply is empty, so nothing is said")
    func empty() {
        #expect(SpokenText.prepare("").isEmpty)
        #expect(SpokenText.prepare(" \n ").isEmpty)
        #expect(SpokenText.prepare("**").isEmpty)
    }

    @Test("a long reply is cut at the end of a sentence")
    func longReply() {
        let sentence = "This is a fairly ordinary sentence. "
        let text = String(repeating: sentence, count: 40)
        let spoken = SpokenText.prepare(text, limit: 200)
        #expect(spoken.count <= 200)
        #expect(spoken.hasSuffix("sentence."))
    }

    @Test("with no sentence end to cut at, it cuts at a word")
    func noSentenceEnd() {
        let text = String(repeating: "word ", count: 100)
        let spoken = SpokenText.prepare(text, limit: 50)
        #expect(spoken.count <= 51)
        #expect(spoken.hasSuffix("word."))
    }

    @Test("a reply within the limit is never cut")
    func withinLimit() {
        let text = String(repeating: "Short. ", count: 50).trimmingCharacters(in: .whitespaces)
        #expect(SpokenText.prepare(text, limit: 1_000) == text)
    }
}
