import Foundation

/// Rebuilds a running transcript from `SpeechAnalyzer`-style results.
///
/// The analyzer reports *volatile* results (a fast, revisable guess for the audio it hasn't committed yet) and
/// *final* results (committed text for a time range). The visible transcript is every finalized segment followed by
/// the latest volatile guess. This type is pure so the tricky bookkeeping can be unit-tested without the framework.
struct TranscriptAssembler: Equatable {
    /// Joins segments. Languages written without spaces (Chinese, Japanese, Thai) use an empty separator.
    let separator: String

    private(set) var finalized: [String] = []
    private(set) var volatile = ""

    init(separator: String = " ") {
        self.separator = separator
    }

    init(locale: Locale) {
        let unspaced: Set<String> = ["zh", "ja", "th"]
        let language = locale.language.languageCode?.identifier ?? ""
        self.init(separator: unspaced.contains(language) ? "" : " ")
    }

    /// Applies one result and returns the transcript to display.
    @discardableResult
    mutating func apply(text: String, isFinal: Bool) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !cleaned.isEmpty { finalized.append(cleaned) }
            volatile = ""
        } else {
            volatile = cleaned
        }
        return current
    }

    /// Finalized text plus the pending volatile guess.
    var current: String {
        (finalized + (volatile.isEmpty ? [] : [volatile])).joined(separator: separator)
    }

    /// The text to report as final once input has ended: anything still volatile is promoted, since the analyzer
    /// will not revise it any further.
    var finalText: String { current }
}
