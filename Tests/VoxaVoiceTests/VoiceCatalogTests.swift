import Foundation
import Testing
@testable import VoxaVoice

@Suite("VoiceCatalog")
struct VoiceCatalogTests {
    private let voices = [
        VoiceInfo(id: "samantha", name: "Samantha", language: "en-US", quality: .standard),
        VoiceInfo(id: "ava", name: "Ava", language: "en-US", quality: .premium),
        VoiceInfo(id: "rishi", name: "Rishi", language: "en-IN", quality: .standard),
        VoiceInfo(id: "lekha", name: "Lekha", language: "hi-IN", quality: .enhanced),
        VoiceInfo(id: "thomas", name: "Thomas", language: "fr-FR", quality: .enhanced),
    ]

    @Test("a voice chosen in Settings is used if it is installed")
    func preferred() {
        #expect(VoiceCatalog.choose(from: voices, preferred: "samantha", language: "en_US")?.id == "samantha")
    }

    @Test("a chosen voice that has been removed falls back to the best for the language")
    func preferredMissing() {
        #expect(VoiceCatalog.choose(from: voices, preferred: "gone", language: "en_US")?.id == "ava")
        #expect(VoiceCatalog.choose(from: voices, preferred: "", language: "en_US")?.id == "ava")
    }

    @Test("the user's own region wins over a more natural voice from another region")
    func region() {
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: "en_IN")?.id == "rishi")
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: "en-IN")?.id == "rishi")
    }

    @Test("with no voice for the region, the best one for the language is used")
    func language() {
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: "en_GB")?.id == "ava")
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: "fr_CA")?.id == "thomas")
    }

    @Test("a language with no voice at all gives none, so the system's own default is used")
    func none() {
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: "ja_JP") == nil)
        #expect(VoiceCatalog.choose(from: voices, preferred: nil, language: nil) == nil)
        #expect(VoiceCatalog.choose(from: [], preferred: "x", language: "en_US") == nil)
    }

    @Test("a picker lists the recognition language's voices first, most natural first, then the rest")
    func sorted() {
        let order = VoiceCatalog.sorted(voices, for: "en_US").map(\.id)
        #expect(Array(order.prefix(3)) == ["ava", "rishi", "samantha"] || Array(order.prefix(3)) == ["ava", "samantha", "rishi"])
        #expect(Set(order.prefix(3)) == ["ava", "samantha", "rishi"])
        #expect(order.prefix(3).first == "ava")
        #expect(Set(order.suffix(2)) == ["lekha", "thomas"])
    }

    @Test("labels name the voice, its language and how natural it is")
    func labels() {
        let english = Locale(identifier: "en_US")
        #expect(VoiceCatalog.label(voices[0], locale: english) == "Samantha (English (United States))")
        #expect(VoiceCatalog.label(voices[1], locale: english).hasSuffix("· Premium"))
        #expect(VoiceCatalog.label(voices[3], locale: english).hasSuffix("· Enhanced"))
    }

    @Test("locale identifiers and language tags are the same thing")
    func normalize() {
        #expect(VoiceCatalog.normalize("en_IN") == "en-IN")
        #expect(VoiceCatalog.normalize("en-IN") == "en-IN")
    }
}
