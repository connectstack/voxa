import Foundation

/// Cleans what Whisper writes. Given noise or silence it doesn't stay quiet: it writes what it has seen in its training data
/// next to such audio (`[BLANK_AUDIO]`, `(music)`, a row of music notes), and none of that is something the person said.
enum WhisperText {
    /// Removes annotations of sounds, music notes and stray whitespace, leaving only the words.
    static func clean(_ raw: String) -> String {
        var text = raw
        // "[BLANK_AUDIO]", "[Music]", "(applause)", "(speaking in foreign language)": Whisper's descriptions of sounds.
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !"♪♫♬♩".unicodeScalars.contains($0) }))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The largest sample in the audio, ignoring sign, which is how loud its loudest moment was (0 to 1).
    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }
}
