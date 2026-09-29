import Foundation

/// Cleans text that comes from outside the app before a model reads it or a person is asked to approve it.
///
/// Two different jobs, because the two readers fail in different ways:
/// - **The model** must not receive characters that are invisible to people but readable to a model (Unicode "tag"
///   characters can carry a whole hidden instruction), and must not be confused by control characters. `forModel` removes them.
/// - **The person** approving an action must see exactly what will run. A right-to-left override can make `evil.com`
///   display as `moc.live`, and a zero-width character can hide inside a script. `forDisplay` never hides anything: it
///   shows each such character as a visible `⟦U+202E⟧` marker, which is itself a warning.
public enum TextSanitizer {
    /// Characters with no visible glyph of their own, or that reorder the text around them.
    static func isInvisibleOrReordering(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F: true   // control characters except tab, newline, return
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x180E, 0x3164, 0xFFA0: true   // soft hyphen, joiners and fillers
        case 0x200B...0x200F: true       // zero-width space and joiners, left/right marks
        case 0x202A...0x202E: true       // bidirectional embeddings and overrides
        case 0x2060...0x206F: true       // word joiner, invisible operators, bidirectional isolates
        case 0xFEFF: true                // byte order mark / zero-width no-break space
        case 0xFFF9...0xFFFB: true       // interlinear annotation
        case 0xE0000...0xE007F: true     // tag characters: invisible text smuggling
        case 0xE0100...0xE01EF: true     // variation selectors supplement
        default: false
        }
    }

    /// Joiners that carry meaning in emoji sequences and in Persian and Indic scripts, so `forModel` keeps them.
    private static func isMeaningfulJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D
    }

    /// Removes invisible and reordering characters, keeping the joiners that languages and emoji need.
    public static func forModel(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isInvisibleOrReordering(scalar) || isMeaningfulJoiner(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// Replaces every invisible or reordering character with a visible marker, so nothing can hide in what a person reviews.
    public static func forDisplay(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if isInvisibleOrReordering(scalar) {
                result += "⟦U+" + String(format: "%04X", scalar.value) + "⟧"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isInvisibleOrReordering)
    }
}
