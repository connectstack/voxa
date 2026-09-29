import Foundation

/// The envelope that marks text as *data* on its way to the model.
///
/// Anything that did not come from the user's own voice (a script's output, the clipboard, a file, a web page, a window
/// title) reaches the model only inside this envelope. The system prompt tells the model that everything between the
/// opening tag and its matching closing tag is data and never an instruction.
///
/// The envelope is only as good as its closing tag, so the tag carries a fresh random **boundary** that the content
/// cannot know in advance. A page that says `</untrusted_data>` (or guesses a boundary) does not end the envelope; the
/// content is also scrubbed of the envelope's own tag name and of invisible characters, and length-limited.
public enum UntrustedData {
    /// Enough for a long email or a page of text; a runaway result shouldn't fill the model's context.
    public static let defaultCharacterLimit = 20_000

    public static func wrap(
        _ text: String,
        source: String,
        limit: Int = defaultCharacterLimit,
        boundary: String? = nil
    ) -> String {
        var body = TextSanitizer.forModel(text)
        // The envelope's own vocabulary must not appear in the content, in any capitalization.
        body = body.replacingOccurrences(of: "untrusted_data", with: "untrusted data", options: .caseInsensitive)

        var note = ""
        if body.count > limit {
            let dropped = body.count - limit
            body = String(body.prefix(limit))
            note = "\n[\(dropped) more characters were cut off]"
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = "(empty)"
        }

        var chosen = boundary ?? randomBoundary()
        // Astronomically unlikely, but the guarantee is cheap: never let the content contain its own boundary.
        while body.contains(chosen) {
            chosen = randomBoundary()
        }
        return """
        <untrusted_data source="\(label(source))" boundary="\(chosen)">
        \(body)\(note)
        </untrusted_data boundary="\(chosen)">
        """
    }

    /// The label is chosen by Voxa's own code, but it goes inside a tag, so it is restricted anyway.
    public static func label(_ source: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:-")
        let cleaned = String(source.filter { allowed.contains($0) }.prefix(60))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func randomBoundary() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%016llx", generator.next() as UInt64)
    }
}
