import Foundation
import Testing
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

@Suite("clipboard_read") struct ClipboardReadTests {
    private func run(_ content: ClipboardContent) async throws -> ToolResult {
        try await ClipboardReadTool(clipboard: FakeClipboard(content)).execute([:], context: ToolContext())
    }

    @Test("text on the clipboard is returned as untrusted data, with a notice that it was read")
    func text()
        async throws {
        let result = try await run(.text("meeting at 3"))
        #expect(result.plainText == "meeting at 3")
        #expect(result.provenance == .untrusted(source: "clipboard"))
        #expect(result.notice == "Read the clipboard")
        #expect(!result.isError)
    }

    @Test("something a password manager marked as secret is never read, and the reply says why")
    func concealed()
        async throws {
        let result = try await run(.concealed)
        #expect(result.isError)
        #expect(result.plainText.contains("marked as secret"))
        #expect(result.provenance == .trusted)
    }

    @Test("an empty clipboard, and one holding an image, are plain sentences with no outside data")
    func nothing()
        async throws {
        let empty = try await run(.empty)
        #expect(empty.plainText == "The clipboard is empty." && empty.provenance == .trusted)
        let image = try await run(.other("an image"))
        #expect(image.plainText.contains("an image") && image.provenance == .trusted)
    }

    @Test("a huge clipboard is cut, and the reply says how much there was")
    func huge() async throws {
        let text = String(repeating: "a", count: ClipboardReadTool.maxCharacters + 500)
        let result = try await run(.text(text))
        #expect(result.plainText.hasPrefix(String(repeating: "a", count: ClipboardReadTool.maxCharacters)))
        #expect(result.plainText.contains("holds \(ClipboardReadTool.maxCharacters + 500) characters"))
        #expect(result.plainText.count < text.count)
    }

    @Test("the policy shows a notice for a read, and asks after outside content or under strict settings")
    func policy()
        throws {
        let tool = ClipboardReadTool(clipboard: FakeClipboard())
        let assessment = try tool.assess([:])
        #expect(assessment.risk == .reversible)
        #expect(
            PolicyFloors.floor(for: tool.name) == .reversible,
            "the floor holds even if the tool's own risk were lowered"
        )

        let standard = PolicyEngine().evaluate(
            toolName: tool.name,
            baselineRisk: tool.baselineRisk,
            assessment: assessment,
            taint: RunTaint()
        )
        #expect(standard == .allowWithNotice("Read the clipboard"))

        var taint = RunTaint()
        taint.absorb(.text("x", provenance: .untrusted(source: "web page")))
        let tainted = PolicyEngine().evaluate(
            toolName: tool.name,
            baselineRisk: tool.baselineRisk,
            assessment: assessment,
            taint: taint
        )
        guard case .requireConfirmation = tainted else {
            Issue.record("expected a confirmation once outside content is in play, got \(tainted)")
            return
        }
    }

    @Test("it takes no arguments, and the schema says so")
    func schema() {
        let tool = ClipboardReadTool(clipboard: FakeClipboard())
        #expect(!InputValidator.validate(["text": "x"], against: tool.inputSchema).isEmpty)
        #expect(InputValidator.validate([:], against: tool.inputSchema).isEmpty)
    }
}

@Suite("clipboard_write") struct ClipboardWriteTests {
    private let clipboard = FakeClipboard(.text("old"))

    private func tool() -> ClipboardWriteTool { ClipboardWriteTool(clipboard: clipboard) }

    @Test("it replaces the clipboard's text and says how much it copied")
    func writes() async throws {
        let result = try await tool().execute(["text": "42 Main Street"], context: ToolContext())
        #expect(clipboard.writes == ["42 Main Street"])
        #expect(result.plainText == "Copied 14 characters to the clipboard.")
        #expect(result.notice == "Copied to the clipboard")
        #expect(result.provenance == .trusted)
    }

    @Test("a single character is singular")
    func singular() async throws {
        #expect(
            try await tool().execute(["text": "x"], context: ToolContext()).plainText
                == "Copied 1 character to the clipboard."
        )
    }

    @Test("empty text is refused, and nothing is written")
    func empty() async {
        await #expect(throws: ToolInputError.self) { try await tool().execute(["text": ""], context: ToolContext()) }
        #expect(clipboard.writes.isEmpty)
    }

    @Test("the card shows what will be copied, cutting a long text but never hiding that it is long")
    func assessment()
        throws {
        let short = try tool().assess(["text": "hello"])
        #expect(short.risk == .reversible)
        #expect(short.details == [DetailRow("Text", "hello", style: .code)])
        #expect(short.reasons.contains { $0.contains("Replaces") })

        let long = try tool().assess(["text": .string(String(repeating: "z", count: 1_000))])
        let preview = try #require(long.details.first?.value)
        #expect(preview.contains("700 more characters"))
        #expect(preview.count < 400)
    }

    @Test("hidden characters in the text are shown as markers on the card")
    func hiddenCharacters() throws {
        let assessment = try tool().assess(["text": "safe\u{202E}evil"])
        let prompt = PolicyEngine(configuration: PolicyConfiguration(strictness: .strict)).evaluate(
            toolName: "clipboard_write",
            baselineRisk: .reversible,
            assessment: assessment,
            taint: RunTaint()
        )
        guard case .requireConfirmation(let card) = prompt else {
            Issue.record("expected a confirmation under strict settings")
            return
        }
        #expect(card.details.first?.value.contains("⟦U+202E⟧") == true)
    }

    @Test("the length limit is in the schema")
    func schema() {
        let tool = tool()
        #expect(
            !InputValidator.validate(
                ["text": .string(String(repeating: "x", count: ClipboardWriteTool.maxCharacters + 1))],
                against: tool.inputSchema
            ).isEmpty
        )
        #expect(!InputValidator.validate([:], against: tool.inputSchema).isEmpty)
    }
}

@Suite("get_frontmost_context") struct FrontmostContextToolTests {
    private func run(_ context: FrontmostContext?) async throws -> ToolResult {
        try await FrontmostContextTool(provider: FakeFrontmost(context)).execute([:], context: ToolContext())
    }

    @Test("with Accessibility it gives the app, the window and the selection, as untrusted data")
    func full()
        async throws {
        let result = try await run(
            FrontmostContext(
                appName: "Safari",
                bundleID: "com.apple.Safari",
                windowTitle: "Swift Concurrency",
                selectedText: "actors isolate state",
                accessibilityGranted: true
            )
        )
        #expect(result.plainText.contains("Frontmost app: Safari (com.apple.Safari)"))
        #expect(result.plainText.contains("Window title: Swift Concurrency"))
        #expect(result.plainText.contains("Selected text: actors isolate state"))
        #expect(result.provenance == .untrusted(source: "the frontmost app"))
    }

    @Test("with Accessibility but nothing selected it says so")
    func nothingSelected() async throws {
        let result = try await run(
            FrontmostContext(
                appName: "Notes",
                bundleID: "com.apple.Notes",
                windowTitle: "Groceries",
                accessibilityGranted: true
            )
        )
        #expect(result.plainText.contains("Nothing is selected."))
    }

    @Test("without Accessibility it gives only the app, says why, and carries no outside text")
    func limited()
        async throws {
        let result = try await run(
            FrontmostContext(appName: "Safari", bundleID: "com.apple.Safari", accessibilityGranted: false)
        )
        #expect(result.plainText.contains("Frontmost app: Safari"))
        #expect(result.plainText.contains("Accessibility is off"))
        #expect(result.plainText.contains("Voxa Settings → Permissions"))
        #expect(result.provenance == .trusted)
    }

    @Test("even with Accessibility, an app with no window title and no selection adds no outside text")
    func onlyAppName() async throws {
        let result = try await run(FrontmostContext(appName: "Finder", accessibilityGranted: true))
        #expect(result.plainText.hasPrefix("Frontmost app: Finder"))
        #expect(result.provenance == .trusted)
    }

    @Test("a very long selection is cut")
    func longSelection() async throws {
        let selection = String(repeating: "s", count: FrontmostContextTool.maxSelectedCharacters + 100)
        let result = try await run(
            FrontmostContext(appName: "Pages", selectedText: selection, accessibilityGranted: true)
        )
        #expect(result.plainText.count < selection.count)
        #expect(result.plainText.contains("…"))
    }

    @Test("no app in front is a plain sentence")
    func none() async throws {
        #expect(try await run(nil).plainText == "No app is in front.")
    }

    @Test("it is read-only, needs no permission up front, and takes no arguments")
    func metadata() {
        let tool = FrontmostContextTool(provider: FakeFrontmost())
        #expect(tool.baselineRisk == .readOnly)
        #expect(tool.requiredPermissions.isEmpty)
        #expect(!InputValidator.validate(["x": 1], against: tool.inputSchema).isEmpty)
    }
}
