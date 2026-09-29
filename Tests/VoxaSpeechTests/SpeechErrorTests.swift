import Foundation
import Testing
import VoxaCore
@testable import VoxaSpeech

@Suite("Speech errors")
struct SpeechErrorTests {
    @Test("Speech framework errors are classified", arguments: [
        ("kAFAssistantErrorDomain", 1110, SFSpeechErrorClassification.noSpeech),
        ("kAFAssistantErrorDomain", 301, .cancelled),
        ("kAFAssistantErrorDomain", 216, .cancelled),
        (NSCocoaErrorDomain, NSUserCancelledError, .cancelled),
    ])
    func classification(domain: String, code: Int, expected: SFSpeechErrorClassification) {
        let error = NSError(domain: domain, code: code)
        #expect(SFSpeechErrorClassification.classify(error) == expected)
    }

    @Test("anything else is a failure carrying the system's description")
    func unknownFailure() {
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 1101, userInfo: [NSLocalizedDescriptionKey: "model missing"])
        #expect(SFSpeechErrorClassification.classify(error) == .failure(.recognitionFailed("model missing")))
    }

    @Test("not being authorized points at the Speech Recognition pane")
    func notAuthorized() {
        let error = SpeechError.notAuthorized(.denied).userFacing
        #expect(error.recovery == .openSystemSettings(.speechRecognition))
        #expect(error.title.contains("Speech Recognition"))
    }

    @Test("a missing on-device model names the language and never suggests sending audio to a server")
    func onDeviceUnavailable() {
        let error = SpeechError.onDeviceUnavailable(languageName: "Hindi (India)").userFacing
        #expect(error.title.contains("Hindi (India)"))
        #expect(error.detail.contains("never sends"))
        #expect(error.recovery == .openAppSettings)
    }

    @Test("every error has a title and a detail", arguments: [
        SpeechError.unsupportedLocale("xx"),
        .recognizerUnavailable,
        .recognitionFailed("why"),
        .modelDownloadFailed("offline"),
    ])
    func wording(error: SpeechError) {
        #expect(!error.userFacing.title.isEmpty)
        #expect(!error.userFacing.detail.isEmpty)
    }

    @Test("the language list is sorted by display name")
    func languagesSorted() {
        let languages = SpeechLanguages.available()
        #expect(!languages.isEmpty)
        let names = languages.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(Set(languages.map(\.id)).count == languages.count)
    }
}
