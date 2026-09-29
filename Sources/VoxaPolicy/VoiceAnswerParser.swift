import Foundation

public enum VoiceAnswer: Sendable, Equatable {
    case yes
    case no
    /// Anything else. The HUD keeps waiting; nothing is approved or denied.
    case unclear
}

/// Turns a spoken reply to a confirmation into yes, no or unclear.
///
/// Approving by voice has to be strict, because a misheard word must never approve an action. So:
/// - **Yes only when the whole utterance is a yes.** "Yes" and "go ahead" approve. "Yes, and also delete the rest", "yes
///   but not that one" and "yes wait" do not: they are unclear.
/// - **No is liberal.** Any negative word without a positive one denies, because a wrong "no" costs a repeated request and a
///   wrong "yes" costs an action the user didn't want.
/// - A reply with both positive and negative words is unclear.
public enum VoiceAnswerParser {
    private static let fillers: Set<String> = [
        "ok", "okay", "alright", "um", "uh", "well", "so", "please", "thanks", "thank", "you", "voxa",
    ]

    /// Words that may appear in a yes and nothing else. Any word outside this set makes the utterance unclear.
    private static let yesVocabulary: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "approve", "approved", "allow", "proceed",
        "affirmative",
        "ahead", "go", "do", "it", "for", "that", "this",
    ]

    /// Yes-words-only utterances that contain no explicit yes word but are still unmistakable.
    private static let bareYesPhrases: Set<[String]> = [["do", "it"], ["do", "that"], ["go", "for", "it"]]

    private static let positiveWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "approve", "approved", "allow", "proceed",
        "affirmative", "ahead",
    ]

    private static let negativeWords: Set<String> = [
        "no", "nope", "nah", "cancel", "stop", "dont", "deny", "denied", "decline", "abort", "negative", "never",
        "wait",
        "hold", "not", "nothing", "nevermind",
    ]

    public static func parse(_ transcript: String) -> VoiceAnswer {
        let words = normalize(transcript)
        guard !words.isEmpty else { return .unclear }

        let hasNegative = words.contains { negativeWords.contains($0) }
        let hasPositive = words.contains { positiveWords.contains($0) }

        if hasNegative && hasPositive { return .unclear }
        if hasNegative { return .no }

        // A yes counts only when nothing else was said. Fillers around it are ignored and repeats are collapsed, but a
        // single word outside the yes vocabulary ("yes and delete everything") makes the whole utterance unclear.
        let core = collapseRepeats(words.filter { !fillers.contains($0) })
        guard !core.isEmpty, core.allSatisfy({ yesVocabulary.contains($0) }) else { return .unclear }
        return hasPositive || bareYesPhrases.contains(core) ? .yes : .unclear
    }

    /// Lower-cased words with punctuation and apostrophes removed ("Don't!" becomes "dont").
    static func normalize(_ transcript: String) -> [String] {
        let folded = transcript.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        )
        var cleaned = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                cleaned += " "
            }
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    private static func collapseRepeats(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words where result.last != word {
            result.append(word)
        }
        return result
    }
}
