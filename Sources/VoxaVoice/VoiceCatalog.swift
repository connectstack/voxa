import Foundation

/// Choosing among the installed voices. Pure, so the choice is tested without any voice installed.
public enum VoiceCatalog {
    /// `en_IN` and `en-IN` are the same language; voices use the second form.
    public static func normalize(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-")
    }

    private static func languageCode(_ tag: String) -> String {
        normalize(tag).split(separator: "-").first.map { String($0).lowercased() } ?? tag.lowercased()
    }

    /// The voice to use: the one asked for if it is installed, otherwise the most natural one for the language, preferring the
    /// user's own region (`en-IN`) to another region of the same language (`en-US`).
    public static func choose(from voices: [VoiceInfo], preferred: String?, language: String?) -> VoiceInfo? {
        if let preferred, !preferred.isEmpty, let match = voices.first(where: { $0.id == preferred }) { return match }
        guard let language, !language.isEmpty else { return nil }

        let wanted = normalize(language)
        let code = languageCode(wanted)
        let candidates = voices.filter { languageCode($0.language) == code }
        return candidates.max { lhs, rhs in
            let left = (normalize(lhs.language).caseInsensitiveCompare(wanted) == .orderedSame ? 1 : 0, lhs.quality)
            let right = (normalize(rhs.language).caseInsensitiveCompare(wanted) == .orderedSame ? 1 : 0, rhs.quality)
            return left.0 != right.0 ? left.0 < right.0 : left.1 < right.1
        }
    }

    /// Voices for a picker: the ones in `language` first, most natural first, then all the others by language and name.
    public static func sorted(_ voices: [VoiceInfo], for language: String?) -> [VoiceInfo] {
        let code = language.map(languageCode)
        return voices.sorted { lhs, rhs in
            let leftMatches = code.map { languageCode(lhs.language) == $0 } ?? false
            let rightMatches = code.map { languageCode(rhs.language) == $0 } ?? false
            if leftMatches != rightMatches { return leftMatches }
            if leftMatches, lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// How a voice reads in a menu: `Samantha (English, United States) · Enhanced`.
    public static func label(_ voice: VoiceInfo, locale: Locale = .current) -> String {
        let region = locale.localizedString(forIdentifier: voice.language.replacingOccurrences(of: "-", with: "_")) ?? voice.language
        switch voice.quality {
        case .standard: return "\(voice.name) (\(region))"
        case .enhanced: return "\(voice.name) (\(region)) · Enhanced"
        case .premium: return "\(voice.name) (\(region)) · Premium"
        }
    }
}
