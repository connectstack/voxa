import Foundation
import Testing
@testable import VoxaPolicy

/// Every way to reach a shell, another script, Terminal, or Objective-C from AppleScript that Voxa knows of, written the
/// way a real attacker would write it: other capitalizations, comments and continued lines in the middle of a phrase,
/// bundle identifiers, file paths, dynamic names.
private let forbiddenScripts: [(name: String, source: String)] = [
    ("do shell script", #"do shell script "ls""#),
    ("upper case", #"DO SHELL SCRIPT "ls""#),
    ("mixed case with extra spaces", "Do   Shell\tScript \"ls\""),
    ("continued line", "do ¬\nshell script \"ls\""),
    ("comment between words", "do -- innocent\nshell script \"ls\""),
    ("block comment between words", "do (* nothing to see *) shell script \"ls\""),
    ("hash comment between words", "do # innocent\nshell script \"ls\""),
    ("raw event code", "«event sysoexec» \"ls\""),
    ("do shell script with admin rights", #"do shell script "x" with administrator privileges"#),
    ("run script", #"run script "return 1""#),
    ("run script of a file", #"run script file "Macintosh HD:x.scpt""#),
    ("load script", #"set s to load script file "x""#),
    ("osascript as code", "set osascript to 1"),
    ("terminal do script", #"tell application "Terminal" to do script "ls""#),
    ("terminal activate only", #"tell application "Terminal" to activate"#),
    ("terminal by abbreviation", #"tell app "Terminal" to activate"#),
    ("terminal lower case", #"tell application "terminal" to activate"#),
    ("terminal by bundle id", #"tell application id "com.apple.Terminal" to activate"#),
    ("terminal by path", #"tell application "/System/Applications/Utilities/Terminal.app" to activate"#),
    (
        "terminal by HFS path",
        #"tell application "Macintosh HD:System:Applications:Utilities:Terminal.app" to activate"#
    ),
    ("iTerm2", #"tell application "iTerm2" to create window with default profile"#),
    ("iTerm", #"tell application "iTerm" to activate"#),
    ("Script Editor", #"tell application "Script Editor" to make new document"#),
    ("Automator", #"tell application "Automator" to run"#),
    ("Shortcuts Events", #"tell application "Shortcuts Events" to run shortcut "x""#),
    ("Keychain Access", #"tell application "Keychain Access" to activate"#),
    ("terminal as a string variable", "set t to \"Terminal\"\ntell process t to set frontmost to true"),
    (
        "terminal through System Events",
        #"tell application "System Events" to tell process "Terminal" to keystroke "ls""#
    ),
    ("application chosen at runtime by a variable", "set appName to \"Fin\"\ntell application appName to activate"),
    ("application built from pieces", #"tell application ("Ter" & "minal") to activate"#),
    ("application from the frontmost one", "tell application (path to frontmost application as text) to activate"),
    ("application id from a variable", "tell application id bundleID to activate"),
    ("app abbreviation with an expression", "tell app (name of x) to activate"),
    ("objective-c framework", "use framework \"Foundation\"\nreturn 1"),
    ("current application's", "return current application's NSString's stringWithString:\"x\""),
    ("NSTask", "return NSTask's new()"),
    ("NSAppleScript", "return NSAppleScript's alloc()"),
    ("call method", "call method \"x\" of class \"y\""),
    ("open location", #"open location "applescript://com.apple.scripteditor?action=new&script=say%20hi""#),
    ("class code chevrons", "return «class furl»"),
    ("password phishing dialog", #"display dialog "Enter your password" default answer "" with hidden answer"#),
    ("remote Apple events", #"tell application "Finder" of machine "eppc://user:pw@host/" to quit"#),
    ("remote host string", #"tell application "Finder" to display dialog "eppc://host/Finder""#),
    (
        "code hidden after a nested comment closes",
        "(* outer (* inner *) still comment *)\ntell application \"Terminal\" to activate"
    ),
    (
        "code after an escaped backslash ends the string",
        "set x to \"abc\\\\\"\ntell application \"Terminal\" to activate"
    ),
    ("hidden text-direction characters", "tell application \"Finder\" to activate\u{202E}"),
    ("zero-width character in the script", "tell application \"Fin\u{200B}der\" to activate"),
    (
        "a file that can run code is written",
        #"set f to open for access file "Macintosh HD:tmp:x.command" with write permission"#
    ),
    ("an unclosed string", "display dialog \"hello"),
    ("an unclosed block comment", "(* never closed\ntell application \"Finder\" to activate"),
    ("empty", ""),
    ("only whitespace", "  \n\t "),
]

private let permittedScripts: [(name: String, source: String)] = [
    ("Finder query", #"tell application "Finder" to get name of startup disk"#),
    ("activate Safari", #"tell application "Safari" to activate"#),
    ("abbreviation", #"tell app "Finder" to get name of every disk"#),
    ("by bundle id", #"tell application id "com.apple.Finder" to activate"#),
    ("System Events keystroke", #"tell application "System Events" to keystroke "a" using command down"#),
    (
        "frontmost process name",
        #"tell application "System Events" to get name of first application process whose frontmost is true"#
    ),
    ("application support folder", #"return POSIX path of (path to application support from user domain)"#),
    ("the frontmost application as a value", "set front to path to frontmost application as text\nreturn front"),
    ("volume", "set volume output volume 30"),
    ("dialog", #"display dialog "Hello" buttons {"OK"}"#),
    (
        "multi-line tell",
        "tell application \"Notes\"\n  make new note at folder \"Notes\" with properties {name:\"x\", body:\"y\"}\nend tell"
    ),
    ("osascript mentioned in text", #"display dialog "osascript is a command""#),
    ("Terminal mentioned inside a longer text", #"display dialog "Open Terminal later""#),
    ("a comment that names Terminal", "-- tell application \"Terminal\" to activate\nreturn 1"),
    ("escaped quotes keep text inside the string", #"display dialog "he said \"Terminal\" loudly""#),
    ("a French quotation in text", #"display dialog "Voulez-vous « continuer » ?""#),
    ("a variable called machine name", #"return computer name"#),
    ("continued line in ordinary code", "set x to 1 + ¬\n 2\nreturn x"),
]

@Suite("AppleScriptAnalyzer")
struct AppleScriptAnalyzerTests {
    private func blockReason(_ source: String) -> String? {
        AppleScriptAnalyzer.analyze(source).blockReason
    }

    // MARK: Things that must never run

    @Test("these scripts are refused", arguments: forbiddenScripts)
    func refused(name: String, source: String) {
        #expect(blockReason(source) != nil, "\(name) should be blocked")
    }

    @Test("a script too long to review is refused")
    func tooLong() {
        let script = String(repeating: "display dialog \"hi\"\n", count: 500)
        #expect(script.count > AppleScriptAnalyzer.maxCharacters)
        #expect(blockReason(script)?.contains("too long") == true)
    }

    @Test("the reason tells the model what to do instead")
    func reasons() {
        #expect(blockReason(#"do shell script "ls""#)?.contains("no shell") == true)
        #expect(blockReason(#"open location "https://x.com""#)?.contains("open_url") == true)
        #expect(blockReason("tell application appName to activate")?.contains("in quotes") == true)
    }

    // MARK: Things that may run (after the user confirms)

    @Test("ordinary scripts are not refused", arguments: permittedScripts)
    func permitted(name: String, source: String) {
        // « » inside a string is text, not a raw code.
        #expect(blockReason(source) == nil, "\(name) should be allowed, got: \(blockReason(source) ?? "")")
    }

    // MARK: What the analysis reports

    @Test("target apps are listed once, in order, by their display name")
    func targets() {
        let script = """
            tell application "Finder" to activate
            tell app "Safari" to activate
            tell application id "com.apple.Notes" to activate
            tell application "/Applications/Calendar.app" to activate
            tell application "Finder" to activate
            """
        #expect(AppleScriptAnalyzer.analyze(script).targetApps == ["Finder", "Safari", "com.apple.Notes", "Calendar"])
    }

    @Test("capabilities describe what the script can do, in plain words")
    func capabilities() {
        func caps(_ source: String) -> [String] { AppleScriptAnalyzer.analyze(source).capabilities }
        #expect(
            caps(#"tell application "System Events" to keystroke "x""#) == [
                "Types keystrokes or presses keys in whichever app is in front"
            ]
        )
        #expect(
            caps(#"tell application "System Events" to click button 1 of window 1 of process "X""#).contains(
                "Clicks buttons and menus in other apps"
            )
        )
        #expect(caps(#"tell application "Finder" to delete file "x""#).contains("Deletes items"))
        #expect(caps(#"tell application "Finder" to move file "a" to trash"#).contains("Deletes items"))
        #expect(caps(#"tell application "Finder" to restart"#).contains("Restarts, shuts down, sleeps or logs out"))
        #expect(caps(#"tell application "Mail" to send message 1"#).contains("Sends messages or email"))
        #expect(
            caps(#"tell application "Safari" to do JavaScript "1" in document 1"#).contains(
                "Runs JavaScript inside a web page"
            )
        )
        #expect(caps("set the clipboard to \"x\"").contains("Reads or changes the clipboard"))
        #expect(
            caps(#"tell application "Finder" to duplicate file "a" to folder "b""#).contains(
                "Writes, moves or copies files"
            )
        )
        #expect(caps(#"tell application "Safari" to quit"#).contains("Quits apps"))
        #expect(caps(#"mount volume "smb://server/share""#).contains("Connects to a network volume"))
        #expect(caps(#"tell application "System Settings" to activate"#).contains("Changes system settings"))
        #expect(caps(#"display dialog "hi""#).isEmpty)
    }

    @Test("naming a runnable file type is flagged")
    func executableFiles() {
        let analysis = AppleScriptAnalyzer.analyze(
            #"tell application "Finder" to open file "Macintosh HD:Users:me:tool.command""#
        )
        #expect(analysis.blockReason == nil)
        #expect(analysis.capabilities.contains("Refers to a file that can run code"))
    }

    @Test("line count")
    func lines() {
        #expect(AppleScriptAnalyzer.analyze("a\nb\nc").lineCount == 3)
        #expect(AppleScriptAnalyzer.analyze("single").lineCount == 1)
    }

    // MARK: Reading the way AppleScript reads

    @Test("the tokenizer agrees with AppleScript about comments, strings and continued lines")
    func tokenizer() {
        typealias Token = AppleScriptAnalyzer.Token
        func words(_ source: String) -> [Token] { AppleScriptAnalyzer.Tokenizer.tokenize(source).tokens }

        #expect(words("a -- b\nc") == [.word("a"), .word("c")])
        #expect(words("a # b\nc") == [.word("a"), .word("c")])
        #expect(words("a (* b (* c *) d *) e") == [.word("a"), .word("e")])
        #expect(words(#"a "x \" y" b"#) == [.word("a"), .string("x \" y"), .word("b")])
        #expect(words(#"a "x\\" b"#) == [.word("a"), .string("x\\"), .word("b")])
        #expect(words("a ¬\n b") == [.word("a"), .word("b")])
        #expect(words("--(* not a block\nx") == [.word("x")])
        #expect(words("«event sysoexec»") == [.chevron("event sysoexec")])
        #expect(words("Tell") == [.word("tell")])
    }
}
