import Foundation

/// What Voxa learned about an AppleScript by reading it, before anyone is asked to approve it.
public struct AppleScriptAnalysis: Sendable, Equatable {
    /// Non-nil means the script must never run. Plain words, shown to the user and returned to the model.
    public var blockReason: String?
    /// The applications the script names, in order of first appearance.
    public var targetApps: [String]
    /// What the script can do, in plain words, for the confirmation ("Sends keystrokes to whichever app is in front").
    public var capabilities: [String]
    public var lineCount: Int
}

/// A static reader for AppleScript source.
///
/// **This is a speed bump, not a sandbox.** AppleScript is a general-purpose language with dynamic evaluation, and no
/// scanner can prove a script safe. The real safeguards are that `run_applescript` is *always* sensitive, so a person
/// reads the whole script (this analyzer also lists the apps it controls and what it can do) and says yes, and that it
/// runs out of process with a timeout. What the analyzer adds is refusing, before anyone is asked, the routes that turn
/// AppleScript into a shell or into a way to run other code: `do shell script`, `run script`, Terminal and iTerm,
/// Objective-C bridging, raw Apple event codes, remote machines, and application targets it cannot read.
///
/// It reads the script the way AppleScript does (skipping comments, joining continued lines, keeping strings apart from
/// code), so `do -- hi ¬⏎ shell script` is caught, and it is deliberately conservative: a script it can't understand is
/// refused, and the model is told to rewrite it more plainly.
public enum AppleScriptAnalyzer {
    /// A script longer than this can't be reviewed in a confirmation, so it isn't run.
    public static let maxCharacters = 8_000

    public static func analyze(_ source: String) -> AppleScriptAnalysis {
        let lineCount =
            source.isEmpty ? 0 : source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        var analysis = AppleScriptAnalysis(blockReason: nil, targetApps: [], capabilities: [], lineCount: lineCount)

        if let reason = screen(source) {
            analysis.blockReason = reason
            return analysis
        }
        let (tokens, isMalformed) = Tokenizer.tokenize(source)
        if isMalformed {
            analysis.blockReason = "The script has an unclosed quote or comment."
            return analysis
        }
        if let reason = blockedReason(source: source, tokens: tokens) {
            analysis.blockReason = reason
            return analysis
        }

        analysis.targetApps = literalTargets(in: tokens)
        analysis.capabilities = capabilities(in: tokens, targets: analysis.targetApps)
        analysis.blockReason = executableFileReason(tokens: tokens)
        return analysis
    }

    /// The checks that need no parsing: a script that is empty, too long to review, or hiding characters.
    private static func screen(_ source: String) -> String? {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The script is empty."
        }
        if source.count > maxCharacters {
            return "The script is too long to review (\(source.count) characters; the limit is \(maxCharacters)). "
                + "Split the work into smaller steps."
        }
        // Invisible characters have no legitimate use in a script and are how code hides from a reader.
        let visible = source.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        if TextSanitizer.hasHiddenCharacters(visible) {
            return "The script contains invisible or text-direction characters, which Voxa doesn't run."
        }
        return nil
    }

    // MARK: Tokens

    enum Token: Equatable {
        /// An identifier or keyword, lower-cased. Adjacent words form the phrases AppleScript is made of.
        case word(String)
        /// A string literal's contents, with escapes resolved.
        case string(String)
        case symbol(Character)
        /// `«…»`: raw event and class codes.
        case chevron(String)
    }

    enum Tokenizer {
        /// The tokens, and whether the source ended inside a string, comment, `«…»` or `|…|`. AppleScript refuses such a
        /// script; Voxa does too, rather than guess what a different reader would make of the rest.
        static func tokenize(_ source: String) -> (tokens: [Token], isMalformed: Bool) {
            var lexer = Lexer(scalars: Array(source.unicodeScalars))
            lexer.run()
            return (lexer.tokens, lexer.isMalformed)
        }
    }

    /// Reads AppleScript source the way AppleScript does: comments (`--`, `#`, nested `(* *)`) vanish, strings keep their
    /// escapes, and a line continued with `¬` is one line.
    private struct Lexer {
        let scalars: [Unicode.Scalar]
        var tokens: [Token] = []
        var isMalformed = false
        private var index = 0

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }

        mutating func run() {
            while let scalar = peek() {
                switch scalar {
                case " ", "\t", "\n", "\r", "¬", "\u{00A0}", "\u{2028}", "\u{2029}":
                    index += 1
                case "-" where peek(1) == "-", "#":
                    skipLineComment()
                case "(" where peek(1) == "*":
                    skipBlockComment()
                case "\"":
                    readString()
                case "«":
                    readDelimited(closer: "»") { .chevron($0.lowercased()) }
                case "|":
                    readDelimited(closer: "|") { .word("|" + $0.lowercased() + "|") }
                default:
                    readWordOrSymbol(scalar)
                }
            }
        }

        private mutating func skipLineComment() {
            while let next = peek(), next != "\n", next != "\r" { index += 1 }
        }

        /// Block comments nest, and quotes inside them mean nothing.
        private mutating func skipBlockComment() {
            var depth = 0
            while index < scalars.count {
                if scalars[index] == "(", peek(1) == "*" {
                    depth += 1
                    index += 2
                } else if scalars[index] == "*", peek(1) == ")" {
                    depth -= 1
                    index += 2
                    if depth == 0 { break }
                } else {
                    index += 1
                }
            }
            if depth > 0 { isMalformed = true }
        }

        private mutating func readString() {
            index += 1
            var text = String.UnicodeScalarView()
            var closed = false
            while let next = peek() {
                if next == "\\", let escaped = peek(1) {
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    default: text.append(escaped)
                    }
                    index += 2
                } else if next == "\"" {
                    index += 1
                    closed = true
                    break
                } else {
                    text.append(next)
                    index += 1
                }
            }
            if !closed { isMalformed = true }
            tokens.append(.string(String(text)))
        }

        /// `«…»` and `|…|`: everything up to the closing character.
        private mutating func readDelimited(closer: Unicode.Scalar, make: (String) -> Token) {
            index += 1
            var text = String.UnicodeScalarView()
            while let next = peek(), next != closer {
                text.append(next)
                index += 1
            }
            if peek() == nil { isMalformed = true }
            index += 1
            tokens.append(make(String(text)))
        }

        private mutating func readWordOrSymbol(_ scalar: Unicode.Scalar) {
            guard Self.isWordScalar(scalar) else {
                tokens.append(.symbol(Character(scalar)))
                index += 1
                return
            }
            var text = String.UnicodeScalarView()
            while let next = peek(), Self.isWordScalar(next) {
                text.append(next)
                index += 1
            }
            tokens.append(.word(String(text).lowercased()))
        }
    }

    // MARK: Blocking rules

    /// Phrases (runs of adjacent words) that make a script a way to run other code, with what to tell the model.
    private static let blockedPhrases: [(words: [String], reason: String)] = [
        (["do", "shell", "script"], "Scripts can't run shell commands. Voxa has no shell."),
        (["do", "script"], "Scripts can't drive Terminal or run commands in it."),
        (["run", "script"], "Scripts can't run other scripts."),
        (["load", "script"], "Scripts can't load other scripts."),
        (["osascript"], "Scripts can't run other scripts."),
        (["use", "framework"], "Scripts that use Objective-C frameworks aren't run."),
        (["nstask"], "Scripts that use Objective-C frameworks aren't run."),
        (["nsapplescript"], "Scripts that use Objective-C frameworks aren't run."),
        (["call", "method"], "Scripts can't call arbitrary methods."),
        (["open", "location"], "Scripts can't open addresses. Use the open_url tool, which checks the address."),
        (["with", "administrator", "privileges"], "Scripts can't ask for administrator rights."),
        (["with", "hidden", "answer"], "Scripts can't ask the user to type a password."),
        (["of", "machine"], "Scripts can't control other computers."),
    ]

    /// Applications that run code or expose secrets; controlling them from a script is the same as having a shell.
    private static let blockedApps: Set<String> = [
        "terminal", "iterm", "iterm2", "script editor", "automator", "shortcuts events", "keychain access",
        "com.apple.terminal", "com.googlecode.iterm2", "com.apple.scripteditor2", "com.apple.automator",
        "com.apple.shortcuts.events", "com.apple.keychainaccess",
    ]

    /// Words that can follow `application` without it being a target (`application support`, `application process`).
    private static let neutralAfterApplication: Set<String> = [
        "support", "scripts", "process", "processes", "file", "files", "bundle", "is", "has", "whose", "where", "as",
        "if", "then", "end", "and", "or",
    ]

    private static func blockedReason(source: String, tokens: [Token]) -> String? {
        let lowered = source.lowercased()

        // Belt and braces: the most dangerous phrases are also searched for in the raw text, so a tokenizing mistake
        // can't hide them. This can refuse a script that merely *mentions* them in a string, which is the safe direction.
        let rawPatterns: [(pattern: String, reason: String)] = [
            ("\\bdo\\s+shell\\s+script\\b", "Scripts can't run shell commands. Voxa has no shell."),
            ("\\brun\\s+script\\b", "Scripts can't run other scripts."),
            ("\\bload\\s+script\\b", "Scripts can't load other scripts."),
            ("eppc://", "Scripts can't control other computers."),
        ]
        for (pattern, reason) in rawPatterns where lowered.range(of: pattern, options: .regularExpression) != nil {
            return reason
        }

        if tokens.contains(where: { if case .chevron = $0 { true } else { false } }) {
            return "Scripts that use raw event or class codes («…») aren't run."
        }
        for (words, reason) in blockedPhrases where containsPhrase(words, in: tokens) {
            return reason
        }
        let currentApplication = ["current", "application"]
        if containsPhrase(currentApplication, in: tokens), followedByApostrophe(after: currentApplication, in: tokens) {
            return "Scripts that use Objective-C frameworks aren't run."
        }

        // An application named in a string is a code-running app.
        for token in tokens {
            if case .string(let text) = token, blockedApps.contains(normalizedAppName(text)) {
                return "Scripts can't control \(displayName(of: text)); that would let a script run commands."
            }
        }
        return dynamicTargetReason(tokens: tokens)
    }

    /// `tell application X` where X is not a plain string can name any app at runtime, including Terminal. It is refused.
    private static func dynamicTargetReason(tokens: [Token]) -> String? {
        for (index, token) in tokens.enumerated() {
            guard case .word(let word) = token, word == "application" || word == "app" else { continue }
            if index > 0, case .word(let previous) = tokens[index - 1], systemDefinedApplications.contains(previous) {
                continue
            }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            switch next {
            case nil, .string:
                continue
            case .word("id"):
                if index + 2 < tokens.count, case .string = tokens[index + 2] { continue }
                return dynamicMessage
            case .word(let follower):
                if neutralAfterApplication.contains(follower) { continue }
                return dynamicMessage
            case .symbol, .chevron:
                return dynamicMessage
            }
        }
        return nil
    }

    /// `frontmost application`, `current application`: the system's own references, not a name that could be Terminal.
    private static let systemDefinedApplications: Set<String> = ["frontmost", "front", "current", "default"]

    private static let dynamicMessage =
        "The script chooses which application to control while it runs. "
        + "Name the application in quotes, for example: tell application \"Finder\"."

    // MARK: Targets and capabilities

    /// Applications named by a string right after `application`, `app` or `application id`.
    private static func literalTargets(in tokens: [Token]) -> [String] {
        var targets: [String] = []
        for (index, token) in tokens.enumerated() {
            guard case .word(let word) = token, word == "application" || word == "app" else { continue }
            var position = index + 1
            if position < tokens.count, tokens[position] == .word("id") { position += 1 }
            if position < tokens.count, case .string(let name) = tokens[position] {
                let display = displayName(of: name)
                if !display.isEmpty, !targets.contains(display) { targets.append(display) }
            }
        }
        return targets
    }

    private static func capabilities(in tokens: [Token], targets: [String]) -> [String] {
        var found: [String] = []
        func add(_ text: String, if condition: Bool) {
            if condition, !found.contains(text) { found.append(text) }
        }
        func has(_ words: [String]) -> Bool { containsPhrase(words, in: tokens) }

        add(
            "Types keystrokes or presses keys in whichever app is in front",
            if: has(["keystroke"]) || has(["key", "code"]) || has(["key", "down"])
        )
        add(
            "Clicks buttons and menus in other apps",
            if: has(["click"]) || has(["ui", "element"]) || has(["ui", "elements"]) || has(["perform", "action"])
        )
        add(
            "Deletes items",
            if: has(["delete"]) || has(["empty", "trash"]) || (has(["move"]) && has(["trash"])) || has(["erase"])
        )
        add(
            "Restarts, shuts down, sleeps or logs out",
            if: has(["shut", "down"]) || has(["restart"]) || has(["log", "out"]) || has(["sleep"])
        )
        add(
            "Sends messages or email",
            if: has(["send"]) || has(["reply"]) || has(["forward"]) || has(["outgoing", "message"])
        )
        add("Runs JavaScript inside a web page", if: has(["do", "javascript"]))
        add("Writes, moves or copies files", if: writesFiles(tokens) || has(["duplicate"]) || has(["move"]))
        add("Reads or changes the clipboard", if: has(["the", "clipboard"]) || has(["clipboard"]))
        add("Quits apps", if: has(["quit"]))
        add("Connects to a network volume", if: has(["mount", "volume"]))
        add(
            "Changes system settings",
            if: targets.contains { ["system settings", "system preferences"].contains($0.lowercased()) }
        )
        add("Refers to a file that can run code", if: mentionsExecutableFile(tokens))
        return found
    }

    private static func writesFiles(_ tokens: [Token]) -> Bool {
        containsPhrase(["open", "for", "access"], in: tokens) || containsPhrase(["set", "eof"], in: tokens)
            || containsPhrase(["write"], in: tokens) || containsPhrase(["make", "new", "file"], in: tokens)
    }

    private static let executableExtensions = [
        "command", "sh", "zsh", "bash", "csh", "ksh", "tool", "terminal", "workflow", "scpt", "scptd", "applescript",
        "pkg", "mpkg", "dmg", "jar", "mobileconfig",
    ]

    private static func mentionsExecutableFile(_ tokens: [Token]) -> Bool {
        tokens.contains { token in
            guard case .string(let text) = token else { return false }
            let lowered = text.lowercased()
            return executableExtensions.contains { lowered.hasSuffix("." + $0) }
        }
    }

    /// Writing a file and naming a runnable file type in the same script is how a script stages code to run later.
    private static func executableFileReason(tokens: [Token]) -> String? {
        writesFiles(tokens) && mentionsExecutableFile(tokens)
            ? "The script creates a file that can run code, which Voxa doesn't allow." : nil
    }

    // MARK: Helpers

    private static func containsPhrase(_ words: [String], in tokens: [Token]) -> Bool {
        guard !words.isEmpty, tokens.count >= words.count else { return false }
        for start in 0...(tokens.count - words.count) {
            var matched = true
            for (offset, word) in words.enumerated() where tokens[start + offset] != .word(word) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func followedByApostrophe(after words: [String], in tokens: [Token]) -> Bool {
        guard tokens.count > words.count else { return false }
        for start in 0...(tokens.count - words.count) {
            let window = tokens[start..<(start + words.count)]
            guard window.elementsEqual(words.map(Token.word)) else { continue }
            let next = start + words.count
            guard next < tokens.count, case .symbol(let character) = tokens[next] else { continue }
            if character == "'" || character == "\u{2019}" { return true }
        }
        return false
    }

    /// `"/System/Applications/Utilities/Terminal.app"` and `"Macintosh HD:Applications:Terminal.app"` and `"Terminal"`
    /// all name the same application.
    static func normalizedAppName(_ text: String) -> String {
        displayName(of: text).lowercased()
    }

    static func displayName(of text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == ":" }), name.index(after: slash) < name.endIndex {
            name = String(name[name.index(after: slash)...])
        }
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }
}
