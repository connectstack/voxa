import Foundation

/// Gets text ready to be said. A reply is written for the eye, and reading it out exactly would say "asterisk", spell out a
/// web address letter by letter, or go on for a minute.
public enum SpokenText {
    /// The most a reply is read out. Longer ones are cut at the end of a sentence; the rest is still on screen.
    public static let defaultLimit = 600

    public static func prepare(_ text: String, limit: Int = defaultLimit) -> String {
        var result = text

        // A link written as [words](address) is read as its words.
        result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // A web address read out is noise; the person can see it.
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        // Markdown the model was asked not to write, but sometimes does.
        result = result.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
        // Lines and runs of space become one space; a line break that ended a sentence keeps its full stop.
        result = result.replacingOccurrences(of: #"([^.!?:;,\s])\s*\n+\s*"#, with: "$1. ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.count > limit else { return result }
        return cut(result, to: limit)
    }

    /// Cuts to at most `limit` characters, at a sentence end if there is one in the second half, else at a word.
    private static func cut(_ text: String, to limit: Int) -> String {
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 2 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) + "." }
        return head
    }
}
