import Foundation
import os
import Testing
@testable import VoxaAgent
import VoxaCore
import VoxaLLM
import VoxaPolicy
import VoxaTestSupport

private let fullControl = AppSettings(localeIdentifier: "en_US", fullControl: true)

private func asked(_ events: EventCollector) -> Bool {
    events.events.contains { if case .awaitingConfirmation = $0 { true } else { false } }
}

/// Full control through the whole loop: what stops asking, and everything that does not.
@Suite("AgentLoop: full control")
@MainActor
struct AgentLoopFullControlTests {
    // MARK: What it changes

    @Test("a sensitive action runs without asking, and the panel still says what is happening")
    func sensitiveRuns() async {
        let tool = stub("wipe", .sensitive)
        let confirmations = ScriptedConfirmations()
        let harness = LoopHarness(
            [.response(.call("wipe", ["value": "disk"])), .response(.say("Wiped."))],
            tools: [tool],
            confirmations: confirmations,
            settings: fullControl
        )
        let output = await harness.run()

        #expect(output.result.outcome == .completed)
        #expect(tool.recorder.executed == [["value": "disk"]])
        #expect(confirmations.prompts.isEmpty)
        #expect(!asked(harness.events))
        #expect(harness.events.events.contains(.acting(title: "Run wipe")))
        #expect(
            await harness.audit.summary == [
                "command", "toolProposed:wipe", "policyDecision:wipe:auto", "toolResult:wipe:ok", "reply:completed",
            ]
        )
    }

    @Test("the same call, without full control, asks (nothing else about the run differs)")
    func withoutItItAsks() async {
        let tool = stub("wipe", .sensitive)
        let confirmations = ScriptedConfirmations(.approved)
        let harness = LoopHarness(
            [.response(.call("wipe", ["value": "disk"])), .response(.say("Wiped."))],
            tools: [tool],
            confirmations: confirmations
        )
        _ = await harness.run()

        #expect(confirmations.prompts.count == 1)
        #expect(asked(harness.events))
        #expect(await harness.audit.summary.contains("policyDecision:wipe:confirm"))
        #expect(!(await harness.audit.summary.contains("policyDecision:wipe:auto")))
    }

    @Test("the trail keeps what the question would have said, so History can show why it would have asked")
    func trailKeepsTheQuestion() async throws {
        let read = stub("read_page", .readOnly, result: .text("hello", provenance: .untrusted(source: "web page")))
        let wipe = StubTool(
            "wipe",
            risk: .sensitive,
            assess: { _ in
                ToolAssessment(risk: .sensitive, title: "Wipe it", summary: "Wipes it.", reasons: ["Deletes something"])
            }
        )
        let confirmations = ScriptedConfirmations()
        let harness = LoopHarness(
            [.response(.call("read_page")), .response(.call("wipe", ["value": "x"])), .response(.say("Done."))],
            tools: [read, wipe],
            confirmations: confirmations,
            settings: fullControl
        )
        _ = await harness.run()

        let entries = await harness.audit.entries
        let decision = try #require(entries.first { $0.kind == .policyDecision && $0.tool == "wipe" })
        #expect(decision.outcome == "auto")
        #expect(decision.risk == .sensitive)
        #expect(decision.detail == "Deletes something | " + L10n.Policy.taint(["web page"]))
        #expect(confirmations.prompts.isEmpty)
        #expect(wipe.recorder.count == 1)
    }

    @Test("reading something from outside no longer makes the next change ask")
    func outsideContent() async {
        let read = stub("read_page", .readOnly, result: .text("hello", provenance: .untrusted(source: "web page")))
        let change = stub("change", .reversible)
        let turns: [ScriptedLLM.Turn] = [.response(.call("read_page")), .response(.call("change")), .response(.say("Done."))]

        let control = ScriptedConfirmations()
        let on = LoopHarness(turns, tools: [read, change], confirmations: control, settings: fullControl)
        _ = await on.run()
        #expect(control.prompts.isEmpty)
        #expect(change.recorder.count == 1)

        let normal = ScriptedConfirmations(.approved)
        let off = LoopHarness(turns, tools: [read, change], confirmations: normal)
        _ = await off.run()
        #expect(normal.prompts.count == 1, "without full control, the taint still makes it ask")
    }

    // MARK: Scripts and apps that change the Mac are covered too

    @Test("a script runs without asking, and the trail keeps the script and that it ran on the user's say-so")
    func scriptsRun() async throws {
        let tool = stub("run_applescript", .sensitive)
        let confirmations = ScriptedConfirmations()
        let harness = LoopHarness(
            [.response(.call("run_applescript", ["value": "beep"])), .response(.say("Done."))],
            tools: [tool],
            confirmations: confirmations,
            settings: fullControl
        )
        _ = await harness.run()

        #expect(confirmations.prompts.isEmpty)
        #expect(tool.recorder.executed == [["value": "beep"]])
        let entries = await harness.audit.entries
        let proposed = try #require(entries.first { $0.kind == .toolProposed })
        #expect(proposed.detail?.contains("beep") == true, "what was asked of it is on record")
        #expect(await harness.audit.summary.contains("policyDecision:run_applescript:auto"))
    }

    @Test("an action in an app that changes the Mac itself runs without asking")
    func systemAppsRun() async {
        let tool = StubTool(
            "ui_click",
            risk: .sensitive,
            assess: { _ in
                ToolAssessment(
                    risk: .sensitive,
                    title: "Click in System Settings",
                    summary: "Clicks a button.",
                    reasons: ["System Settings: It changes settings of the Mac."]
                )
            }
        )
        let confirmations = ScriptedConfirmations()
        let harness = LoopHarness(
            [.response(.call("ui_click")), .response(.say("Done."))],
            tools: [tool],
            confirmations: confirmations,
            settings: fullControl
        )
        _ = await harness.run()

        #expect(confirmations.prompts.isEmpty)
        #expect(tool.recorder.count == 1)
    }

    // MARK: What it does not change

    @Test("a blocked call is still blocked, and the model is told not to look for a way round")
    func blockedStaysBlocked() async {
        let tool = StubTool(
            "run_thing",
            risk: .sensitive,
            assess: { _ in ToolAssessment(risk: .sensitive, title: "Run", summary: "Runs.", block: "No shell here.") }
        )
        let confirmations = ScriptedConfirmations()
        let harness = LoopHarness(
            [.response(.call("run_thing")), .response(.say("I couldn't."))],
            tools: [tool],
            confirmations: confirmations,
            settings: fullControl
        )
        _ = await harness.run()

        #expect(tool.recorder.isEmpty)
        #expect(confirmations.prompts.isEmpty)
        let result = harness.llm.requests[1].toolResults[0]
        #expect(result.isError && result.text.contains("No shell here.") && result.text.contains("Don't try to get around"))
        #expect(await harness.audit.summary.contains("policyDecision:run_thing:deny"))
    }

    @Test("a tool the user switched off is still refused")
    func disabledStaysDisabled() async {
        let tool = stub("wipe", .sensitive)
        let harness = LoopHarness(
            [.response(.call("wipe")), .response(.say("No."))],
            tools: [tool],
            settings: AppSettings(localeIdentifier: "en_US", fullControl: true, disabledTools: ["wipe"])
        )
        _ = await harness.run()

        #expect(tool.recorder.isEmpty)
        #expect(harness.llm.requests[1].toolResults[0].isError)
        #expect(await harness.audit.summary.contains("policyDecision:wipe:deny"))
    }

    // MARK: Switching it off part-way

    @Test("switching it off part-way through a command makes the rest of that command ask")
    func offMidway() async throws {
        let stillOn = OSAllocatedUnfairLock(initialState: true)
        let wipe = StubTool(
            "wipe",
            risk: .sensitive,
            run: { _ in
                stillOn.withLock { $0 = false }  // the user reaches for the menu-bar item while the first one runs
                return .text("ok")
            }
        )
        let confirmations = ScriptedConfirmations(.approved)
        let harness = LoopHarness(
            [
                .response(.call("wipe", ["value": "one"], id: "a")), .response(.call("wipe", ["value": "two"], id: "b")),
                .response(.say("Done.")),
            ],
            tools: [wipe],
            confirmations: confirmations,
            settings: fullControl,
            fullControlStillOn: { stillOn.withLock { $0 } }
        )
        _ = await harness.run()

        let decisions = await harness.audit.summary.filter { $0.hasPrefix("policyDecision:wipe") }
        #expect(decisions == ["policyDecision:wipe:auto", "policyDecision:wipe:confirm"])
        let prompt = try #require(confirmations.prompts.first)
        #expect(confirmations.prompts.count == 1)
        #expect(prompt.details.contains { $0.value.contains("two") }, "the second action is the one that asked")
        #expect(wipe.recorder.count == 2, "and it ran once approved")
    }

    @Test("switching it on part-way never gives a command that started without it the right to skip a question")
    func onMidway() async {
        let wipe = stub("wipe", .sensitive)
        let confirmations = ScriptedConfirmations(.approved)
        let harness = LoopHarness(
            [.response(.call("wipe", ["value": "one"])), .response(.say("Done."))],
            tools: [wipe],
            confirmations: confirmations,
            settings: AppSettings(localeIdentifier: "en_US"),
            fullControlStillOn: { true }
        )
        _ = await harness.run()
        #expect(confirmations.prompts.count == 1)
        #expect(await harness.audit.summary.contains("policyDecision:wipe:confirm"))
    }

    @Test("through the service: switching it off in Settings part-way through a command makes the rest of it ask")
    func serviceSeesTheSwitch() async throws {
        let on = OSAllocatedUnfairLock(initialState: true)
        let wipe = StubTool(
            "wipe",
            risk: .sensitive,
            run: { _ in
                on.withLock { $0 = false }
                return .text("ok")
            }
        )
        let confirmations = ScriptedConfirmations(.approved)
        let service = AgentService(
            llm: ScriptedLLM([
                .response(.call("wipe", ["value": "one"], id: "a")), .response(.call("wipe", ["value": "two"], id: "b")),
                .response(.say("Done.")),
            ]),
            registry: ToolRegistry([wipe]),
            confirmations: confirmations,
            systemPrompt: SystemPrompt(template: "test {{max_steps}}"),
            clock: ManualClock(),
            settings: { AppSettings(localeIdentifier: "en_US", fullControl: on.withLock { $0 }) }
        )
        let result = await service.run("wipe twice")

        #expect(result.outcome == .completed)
        #expect(confirmations.prompts.count == 1)
        #expect(try #require(confirmations.prompts.first).details.contains { $0.value.contains("two") })
    }

    // MARK: What the model is told, and which copy of the setting counts

    @Test("the model is told when nothing will be checked, and only then")
    func modelIsTold() async {
        func firstTurn(_ harness: LoopHarness) -> String {
            guard case .text(let text) = harness.llm.requests[0].messages[0].content[0] else { return "" }
            return text
        }
        let on = LoopHarness([.response(.say("Hi."))], settings: fullControl)
        _ = await on.run()
        let told = firstTurn(on)
        #expect(told.contains("Full control: on."))
        #expect(told.contains("can't be undone") && told.contains("ask one short question"))
        #expect(told.hasPrefix("<context>") && told.hasSuffix("do the thing"), "it sits inside Voxa's own facts")

        let off = LoopHarness([.response(.say("Hi."))])
        _ = await off.run()
        #expect(!firstTurn(off).contains("Full control"))
    }

    @Test("a command keeps the setting it started with: changing the setting afterwards changes nothing about it")
    func runKeepsItsCopy() {
        var settings = AppSettings(fullControl: true)
        let configuration = AgentRunConfiguration(settings)
        settings.fullControl = false
        #expect(configuration.fullControl)
        #expect(!AgentRunConfiguration(settings).fullControl)
        #expect(!AgentRunConfiguration(AppSettings()).fullControl)
    }
}
