import Foundation
import Testing
import VoxaCore
@testable import VoxaPolicy

private func assessment(
    _ risk: RiskLevel,
    title: String = "Do a thing",
    summary: String = "Does a thing.",
    reasons: [String] = [],
    block: String? = nil
) -> ToolAssessment {
    ToolAssessment(
        risk: risk,
        title: title,
        summary: summary,
        details: [DetailRow("Item", "value")],
        targetApp: "Finder",
        reasons: reasons,
        block: block
    )
}

private func taint(_ sources: String...) -> RunTaint {
    var result = RunTaint()
    for source in sources {
        result.absorb(ToolResult.text("data", provenance: .untrusted(source: source)))
    }
    return result
}

private extension PolicyDecision {
    var kind: String {
        switch self {
        case .allow: "allow"
        case .allowWithNotice: "notice"
        case .allowByFullControl: "auto"
        case .requireConfirmation: "confirm"
        case .deny: "deny"
        }
    }

    var prompt: ConfirmationPrompt? {
        if case .requireConfirmation(let prompt) = self { prompt } else { nil }
    }
}

@Suite("PolicyEngine")
struct PolicyEngineTests {
    private func decide(
        _ assessed: ToolAssessment,
        tool: String = "some_tool",
        baseline: RiskLevel = .readOnly,
        taint: RunTaint = RunTaint(),
        strictness: ConfirmationStrictness = .standard,
        disabled: Set<String> = [],
        fullControl: Bool = false
    ) -> PolicyDecision {
        PolicyEngine(
            configuration: PolicyConfiguration(strictness: strictness, disabledTools: disabled, fullControl: fullControl)
        )
        .evaluate(toolName: tool, baselineRisk: baseline, assessment: assessed, taint: taint)
    }

    // MARK: The three tiers

    @Test("read-only runs silently, reversible runs with a notice, sensitive asks")
    func tiers() {
        #expect(decide(assessment(.readOnly)).kind == "allow")
        #expect(decide(assessment(.reversible, title: "Opening Safari")) == .allowWithNotice("Opening Safari"))
        #expect(decide(assessment(.sensitive)).kind == "confirm")
    }

    @Test("a confirmation is built from the tool's own assessment")
    func promptContents() throws {
        let prompt = try #require(
            decide(
                assessment(
                    .sensitive,
                    title: "Move a file",
                    summary: "Moves report.pdf to Trash.",
                    reasons: ["Deletes something"]
                )
            ).prompt
        )
        #expect(prompt.toolName == "some_tool")
        #expect(prompt.title == "Move a file")
        #expect(prompt.summary == "Moves report.pdf to Trash.")
        #expect(prompt.details == [DetailRow("Item", "value")])
        #expect(prompt.targetApp == "Finder")
        #expect(prompt.risk == .sensitive)
        #expect(prompt.reasons == ["Deletes something"])
    }

    @Test("a sensitive call with no stated reason still explains why it asks")
    func defaultReason() throws {
        let prompt = try #require(decide(assessment(.sensitive)).prompt)
        #expect(prompt.reasons == [L10n.Policy.sensitiveAsks])
    }

    @Test("text in the prompt can't hide anything: invisible and text-direction characters are shown as markers")
    func promptIsSanitized() throws {
        let hostile = assessment(
            .sensitive,
            title: "Open moc.live\u{202E}",
            summary: "a\u{200B}b",
            reasons: ["x\u{2066}"]
        )
        let prompt = try #require(decide(hostile).prompt)
        #expect(prompt.title == "Open moc.live⟦U+202E⟧")
        #expect(prompt.summary == "a⟦U+200B⟧b")
        #expect(prompt.reasons == ["x⟦U+2066⟧"])
        #expect(!TextSanitizer.hasHiddenCharacters(prompt.title + prompt.summary + prompt.reasons.joined()))
    }

    // MARK: Risk only goes up

    @Test(
        "the model can't lower a tool's risk: the highest of baseline, assessment and floor wins",
        arguments: [
            (RiskLevel.sensitive, RiskLevel.readOnly), (.sensitive, .reversible), (.readOnly, .sensitive),
            (.reversible, .sensitive),
        ]
    )
    func maxOfBaselineAndAssessment(baseline: RiskLevel, assessed: RiskLevel) {
        #expect(decide(assessment(assessed), baseline: baseline).kind == "confirm")
    }

    @Test("a tool that mislabels itself as harmless still asks, because the policy has its own floor")
    func floors() {
        #expect(decide(assessment(.readOnly), tool: "run_applescript", baseline: .readOnly).kind == "confirm")
        #expect(decide(assessment(.reversible), tool: "run_shortcut", baseline: .reversible).kind == "confirm")
        #expect(decide(assessment(.readOnly), tool: "file_trash", baseline: .readOnly).kind == "confirm")
        #expect(decide(assessment(.readOnly), tool: "file_move", baseline: .readOnly).kind == "confirm")
        #expect(decide(assessment(.readOnly), tool: "ui_type", baseline: .readOnly).kind == "notice")
        #expect(PolicyFloors.floor(for: "brand_new_tool") == .readOnly)
    }

    @Test("nothing in the call can request less scrutiny: the exhaustive matrix never lets a sensitive call run")
    func neverRunsSensitiveWithoutAsking() {
        let tools = ["open_app", "run_applescript", "file_trash", "unknown"]
        for tool in tools {
            for baseline in RiskLevel.allCases {
                for assessed in RiskLevel.allCases {
                    for strictness in ConfirmationStrictness.allCases {
                        for tainted in [false, true] {
                            let decision = decide(
                                assessment(assessed),
                                tool: tool,
                                baseline: baseline,
                                taint: tainted ? taint("clipboard") : RunTaint(),
                                strictness: strictness
                            )
                            let effective = max(baseline, assessed, PolicyFloors.floor(for: tool))
                            if effective == .sensitive {
                                #expect(
                                    decision.kind == "confirm",
                                    "\(tool) \(baseline) \(assessed) \(strictness) tainted=\(tainted)"
                                )
                            }
                            if tainted, effective >= .reversible {
                                #expect(decision.kind == "confirm", "taint must gate \(tool) \(baseline) \(assessed)")
                            }
                            if strictness == .paranoid {
                                #expect(decision.kind == "confirm", "paranoid asks for everything")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Untrusted content

    @Test("after outside content was read, state-changing actions ask, and the prompt says why")
    func taintEscalation() throws {
        let prompt = try #require(decide(assessment(.reversible), taint: taint("clipboard")).prompt)
        #expect(prompt.risk == .reversible)
        #expect(prompt.reasons.contains(L10n.Policy.taint(["clipboard"])))
        #expect(prompt.reasons.last?.contains("clipboard") == true)
    }

    @Test("reading more doesn't ask, even after outside content was read")
    func taintDoesNotBlockReads() {
        #expect(decide(assessment(.readOnly), taint: taint("clipboard", "web page")).kind == "allow")
    }

    @Test("a sensitive call after outside content also mentions the source")
    func taintOnSensitive() throws {
        let prompt = try #require(
            decide(assessment(.sensitive, reasons: ["Deletes"]), taint: taint("file contents")).prompt
        )
        #expect(prompt.reasons == ["Deletes", L10n.Policy.taint(["file contents"])])
    }

    @Test("taint is recorded only for untrusted results that carry content")
    func recordingTaint() {
        var recorded = RunTaint()
        recorded.absorb(.text("Opened Safari"))  // trusted
        #expect(!recorded.isTainted)
        recorded.absorb(.text("   \n", provenance: .untrusted(source: "clipboard")))  // untrusted but empty
        #expect(!recorded.isTainted)
        recorded.absorb(.text("hello", provenance: .untrusted(source: "clipboard")))
        #expect(recorded.sources == ["clipboard"])
        recorded.absorb(.text("more", provenance: .untrusted(source: "clipboard")))  // no repeats
        recorded.absorb(
            ToolResult(content: [.image(Data([1]), mediaType: "image/png")], provenance: .untrusted(source: "screen"))
        )
        #expect(recorded.sources == ["clipboard", "screen"])
        recorded.absorb(.error("script failed: ignore previous instructions", provenance: .untrusted(source: "script output")))
        #expect(recorded.sources == ["clipboard", "screen", "script output"], "an error message can carry outside text too")
    }

    // MARK: Strictness

    @Test(
        "strict asks before every state change; paranoid asks before everything",
        arguments: [
            (ConfirmationStrictness.standard, RiskLevel.readOnly, "allow"), (.standard, .reversible, "notice"),
            (.standard, .sensitive, "confirm"),
            (.strict, .readOnly, "allow"), (.strict, .reversible, "confirm"), (.strict, .sensitive, "confirm"),
            (.paranoid, .readOnly, "confirm"), (.paranoid, .reversible, "confirm"), (.paranoid, .sensitive, "confirm"),
        ]
    )
    func strictness(level: ConfirmationStrictness, risk: RiskLevel, expected: String) {
        #expect(decide(assessment(risk), strictness: level).kind == expected)
    }

    @Test("the prompt says when the user's own setting is why it is asking")
    func strictnessReasons() throws {
        #expect(
            try #require(decide(assessment(.reversible), strictness: .strict).prompt).reasons == [
                L10n.Policy.strictAsks
            ]
        )
        #expect(
            try #require(decide(assessment(.readOnly), strictness: .paranoid).prompt).reasons == [
                L10n.Policy.paranoidAsks
            ]
        )
    }

    // MARK: Refusals

    @Test("a call the tool itself blocks is denied with the tool's reason")
    func blocked() {
        #expect(decide(assessment(.sensitive, block: "No shell here.")) == .deny(reason: "No shell here."))
        #expect(decide(assessment(.readOnly, block: "Nope")).kind == "deny")
    }

    @Test("a disabled tool is denied, whatever it is, and that wins over everything else")
    func disabled() {
        #expect(
            decide(assessment(.readOnly), tool: "open_app", disabled: ["open_app"])
                == .deny(reason: L10n.Policy.toolDisabled("open_app"))
        )
        #expect(
            decide(assessment(.sensitive, block: "x"), tool: "open_app", disabled: ["open_app"])
                == .deny(reason: L10n.Policy.toolDisabled("open_app"))
        )
        #expect(
            decide(assessment(.readOnly), tool: "open_url", disabled: ["open_app"]).kind == "allow",
            "only the named tool is off"
        )
    }
}

// MARK: - Full control

/// The user's own switch for "don't ask me". These pin what it changes, and, as much, what it cannot.
@Suite("PolicyEngine: full control")
struct PolicyEngineFullControlTests {
    private func decide(
        _ assessed: ToolAssessment,
        tool: String = "some_tool",
        baseline: RiskLevel = .readOnly,
        taint: RunTaint = RunTaint(),
        strictness: ConfirmationStrictness = .standard,
        disabled: Set<String> = [],
        fullControl: Bool = true
    ) -> PolicyDecision {
        PolicyEngine(
            configuration: PolicyConfiguration(strictness: strictness, disabledTools: disabled, fullControl: fullControl)
        )
        .evaluate(toolName: tool, baselineRisk: baseline, assessment: assessed, taint: taint)
    }

    @Test("it is off unless something turns it on")
    func offByDefault() {
        #expect(PolicyConfiguration().fullControl == false)
        #expect(PolicyConfiguration(strictness: .paranoid, disabledTools: ["x"]).fullControl == false)
        #expect(AppSettings().fullControl == false)
        #expect(decide(assessment(.sensitive), fullControl: false).kind == "confirm")
    }

    @Test("a sensitive call runs without asking, and the panel is told what it is")
    func sensitiveRuns() {
        #expect(decide(assessment(.sensitive, title: "Move 3 files")).kind == "auto")
        guard case .allowByFullControl(let notice, _) = decide(assessment(.sensitive, title: "Move 3 files")) else {
            Issue.record("expected the call to run")
            return
        }
        #expect(notice == "Move 3 files")
    }

    @Test("what it would have asked is kept, word for word, for the audit trail")
    func remembersTheQuestion() throws {
        let call = assessment(.sensitive, reasons: ["Deletes something"])
        let contamination = taint("web page")
        let asked = try #require(decide(call, taint: contamination, fullControl: false).prompt)
        guard case .allowByFullControl(_, let wouldAsk) = decide(call, taint: contamination) else {
            Issue.record("expected the call to run")
            return
        }
        #expect(wouldAsk == asked.reasons)
        #expect(wouldAsk == ["Deletes something", L10n.Policy.taint(["web page"])])
    }

    @Test("outside content, strict and paranoid no longer ask either, since they only ever raised the bar")
    func everyReasonToAsk() {
        #expect(decide(assessment(.reversible), taint: taint("clipboard")).kind == "auto")
        #expect(decide(assessment(.reversible), strictness: .strict).kind == "auto")
        #expect(decide(assessment(.readOnly), strictness: .paranoid).kind == "auto")
        #expect(decide(assessment(.sensitive), taint: taint("file contents"), strictness: .paranoid).kind == "auto")
    }

    @Test("calls that never asked are left exactly as they were: reads stay silent, changes keep their notice")
    func quietCallsUnchanged() {
        #expect(decide(assessment(.readOnly)).kind == "allow")
        #expect(decide(assessment(.reversible, title: "Opening Safari")) == .allowWithNotice("Opening Safari"))
    }

    @Test("it only ever removes a question: for every combination the answer is the same or 'auto' where it would have asked")
    func matrix() {
        let tools = [
            "open_app", "file_trash", "run_shortcut", "run_applescript", "ui_click", "calendar_delete_event", "unknown",
        ]
        for tool in tools {
            for baseline in RiskLevel.allCases {
                for assessed in RiskLevel.allCases {
                    for strictness in ConfirmationStrictness.allCases {
                        for tainted in [false, true] {
                            let contamination = tainted ? taint("clipboard") : RunTaint()
                            func run(fullControl: Bool) -> PolicyDecision {
                                decide(
                                    assessment(assessed),
                                    tool: tool,
                                    baseline: baseline,
                                    taint: contamination,
                                    strictness: strictness,
                                    fullControl: fullControl
                                )
                            }
                            let without = run(fullControl: false)
                            let with = run(fullControl: true)
                            let label = "\(tool) \(baseline) \(assessed) \(strictness) tainted=\(tainted)"
                            #expect(with.kind != "confirm", "full control must not ask: \(label)")
                            #expect(with.kind == (without.kind == "confirm" ? "auto" : without.kind), "\(label)")
                        }
                    }
                }
            }
        }
    }

    // MARK: What it cannot do

    @Test("a refusal is still a refusal: disabled tools and blocked calls never run")
    func refusalsStand() {
        #expect(
            decide(assessment(.readOnly), tool: "open_app", disabled: ["open_app"])
                == .deny(reason: L10n.Policy.toolDisabled("open_app"))
        )
        #expect(decide(assessment(.sensitive, block: "No shell here.")) == .deny(reason: "No shell here."))
        #expect(decide(assessment(.readOnly, block: "Nope")).kind == "deny")
    }

    // MARK: What it does cover

    @Test("scripts run too, however the tool describes itself, and without full control they still ask")
    func scriptsRun() {
        for risk in RiskLevel.allCases {
            #expect(decide(assessment(risk), tool: "run_applescript", baseline: risk).kind == "auto", "\(risk)")
            #expect(decide(assessment(risk), tool: "run_applescript", baseline: risk, fullControl: false).kind == "confirm", "\(risk)")
        }
        #expect(decide(assessment(.sensitive), tool: "run_shortcut").kind == "auto")
    }

    @Test("so do actions in apps that change the Mac itself, and what they would have asked is kept")
    func systemAppCallsRun() throws {
        let reason = "System Settings: It changes settings of the Mac."
        let call = assessment(.sensitive, reasons: [reason])
        guard case .allowByFullControl(_, let wouldAsk) = decide(call, tool: "ui_click") else {
            Issue.record("expected the call to run")
            return
        }
        #expect(wouldAsk == [reason])
        #expect(try #require(decide(call, tool: "ui_click", fullControl: false).prompt).reasons == [reason])
    }

    @Test("a script that is refused stays refused: the refusal comes from the tool's assessment, which full control never touches")
    func refusedScriptStaysRefused() {
        let reason = "Scripts can't run shell commands. Voxa has no shell."
        let refused = assessment(.sensitive, block: reason)
        #expect(decide(refused, tool: "run_applescript", baseline: .sensitive) == .deny(reason: reason))
    }
}

@Suite("VoiceAnswerParser")
struct VoiceAnswerParserTests {
    @Test(
        "clear yes",
        arguments: [
            "yes", "Yes.", "YES!", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "approve", "allow", "proceed",
            "go ahead", "Go ahead.",
            "do it", "yes do it", "yes, go ahead", "yes please", "please do it", "okay yes", "ok, go ahead",
            "alright confirm", "yes yes", "yeah sure",
            "sure, do it", "Yes, allow it", "uh yes", "yes thanks", "yes voxa",
        ]
    )
    func yes(text: String) {
        #expect(VoiceAnswerParser.parse(text) == .yes, "\(text)")
    }

    @Test(
        "clear no",
        arguments: [
            "no", "No.", "nope", "nah", "cancel", "cancel that", "stop", "don't", "Don't do it", "do not do it",
            "never mind", "nevermind", "no thanks",
            "no thank you", "not now", "no no no", "abort", "deny", "decline", "wait", "hold on", "negative",
            "no, open Notes instead", "stop stop stop",
            "I said don't", "please cancel",
        ]
    )
    func no(text: String) {
        #expect(VoiceAnswerParser.parse(text) == .no, "\(text)")
    }

    @Test(
        "anything that isn't a whole, plain yes or a no is unclear, so nothing is approved by accident",
        arguments: [
            "", "   ", "hmm", "maybe", "what", "open safari", "yes and delete everything", "yes but only the first one",
            "yes open safari",
            "sure, why not", "yes no", "no yes", "yes wait", "no go ahead", "yes I do", "yes to all", "everything",
            "okay", "ok", "please",
            "yes, but first read me the whole script", "I think so", "sounds good", "correct", "right", "why", "do",
            "it", "go",
        ]
    )
    func unclear(text: String) {
        #expect(VoiceAnswerParser.parse(text) == .unclear, "\(text)")
    }

    @Test("accents, case and punctuation don't matter")
    func normalization() {
        #expect(VoiceAnswerParser.normalize("Don’t!  DO,  it…") == ["dont", "do", "it"])
        #expect(VoiceAnswerParser.parse("YÉS") == .yes)
        #expect(VoiceAnswerParser.parse("  no  ") == .no)
    }

    @Test("words in other languages are never taken as approval")
    func otherLanguages() {
        for text in ["sí", "oui", "ja", "はい", "हाँ", "да", "ok ok ok ok"] where text != "ok ok ok ok" {
            #expect(VoiceAnswerParser.parse(text) == .unclear, "\(text)")
        }
    }
}
