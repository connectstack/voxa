import Foundation
import os
import Testing
@testable import VoxaAgent
import VoxaCore
import VoxaLLM
import VoxaTestSupport

/// A tool that needs a system permission (Calendars, say) gets it, or the command ends with an error the user can act on.
@MainActor
@Suite("AgentLoop: system permissions")
struct AgentPermissionTests {
    private func calendarTool(
        risk: RiskLevel = .readOnly,
        onAssess: @escaping @Sendable () -> Void = {}
    ) -> StubTool {
        var tool = StubTool(
            "calendar_list_events",
            risk: risk,
            assess: { _ in
                onAssess()
                return ToolAssessment(risk: risk, title: "List events", summary: "Lists events.")
            },
            run: { _ in .text("Dentist at 3") }
        )
        tool.requiredPermissions = [.calendars]
        return tool
    }

    @Test("with the permission, the tool runs as usual and nothing is recorded about permissions")
    func granted() async {
        let permissions = ScriptedToolPermissions()
        let tool = calendarTool()
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"])), .response(.say("You have the dentist."))],
            tools: [tool],
            permissions: permissions
        )
        let output = await harness.run()
        #expect(output.result.outcome == .completed)
        #expect(tool.recorder.count == 1)
        #expect(permissions.asked == [[.calendars]])
        #expect(await !harness.audit.summary.contains { $0.hasPrefix("permission") })
    }

    @Test("a refused permission ends the command with the error that carries the button, and the tool never runs")
    func denied() async {
        let permissions = ScriptedToolPermissions([.calendars: .denied])
        let tool = calendarTool()
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"])), .response(.say("never"))],
            tools: [tool],
            permissions: permissions
        )
        let output = await harness.run()

        guard case .failed(let error) = output.result.outcome else {
            Issue.record("expected the command to fail, got \(output.result.outcome)")
            return
        }
        #expect(error == .permissionRequired(.calendars, status: .denied))
        #expect(error.recovery == .openSystemSettings(.calendars))
        #expect(tool.recorder.isEmpty)
        #expect(harness.llm.requestCount == 1, "the model isn't asked to write around a permission it can't have")
        #expect(await harness.audit.summary.contains("permission:calendar_list_events:denied"))
    }

    @Test("a permission restricted by policy fails the same way, with no button")
    func restricted() async {
        let permissions = ScriptedToolPermissions([.calendars: .restricted])
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"]))], tools: [calendarTool()], permissions: permissions
        )
        guard case .failed(let error) = await harness.run().result.outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.recovery == nil)
    }

    @Test("the permission is checked before the tool describes the call")
    func checkedBeforeAssessing() async {
        let order = OrderLog()
        let permissions = ScriptedToolPermissions([.calendars: .denied])
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"]))],
            tools: [calendarTool(onAssess: { order.add("assess") })],
            permissions: permissions
        )
        _ = await harness.run()
        #expect(order.entries.isEmpty, "a tool that reads the calendar to describe its call must not do so without access")
    }

    @Test("Automation is not asked about ahead of time: macOS asks per app when a script first controls one")
    func automationSkipped() async {
        let permissions = ScriptedToolPermissions([.automation: .notDetermined])
        var script = StubTool("run_applescript", risk: .sensitive)
        script.requiredPermissions = [.automation]
        let harness = LoopHarness(
            [.response(.call("run_applescript", ["value": "x"])), .response(.say("Done."))],
            tools: [script],
            confirmations: ScriptedConfirmations(.approved),
            permissions: permissions
        )
        let output = await harness.run()
        #expect(output.result.outcome == .completed)
        #expect(permissions.asked.isEmpty)
        #expect(script.recorder.count == 1)
    }

    @Test("a tool the user switched off is refused without ever asking macOS for its permission")
    func disabledToolDoesNotPrompt() async {
        let permissions = ScriptedToolPermissions([.calendars: .notDetermined])
        let tool = calendarTool()
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"])), .response(.say("I can't do that."))],
            tools: [tool],
            permissions: permissions,
            settings: AppSettings(localeIdentifier: "en_US", disabledTools: ["calendar_list_events"])
        )
        let output = await harness.run()
        #expect(permissions.asked.isEmpty, "no prompt for something that won't be run")
        #expect(tool.recorder.isEmpty)
        #expect(await harness.audit.summary.contains("policyDecision:calendar_list_events:deny"))
        #expect(output.result.outcome == .completed, "the model is told it is off and carries on")
    }

    @Test("a tool that needs nothing never asks")
    func needsNothing() async {
        let permissions = ScriptedToolPermissions()
        let harness = LoopHarness(
            [.response(.call("look_up", ["value": "x"])), .response(.say("ok"))],
            tools: [stub("look_up", .readOnly)],
            permissions: permissions
        )
        _ = await harness.run()
        #expect(permissions.asked.isEmpty)
    }

    @Test("the command's clock stops while the system prompt is up, and the command carries on when it is answered")
    func promptDoesNotSpendTheBudget() async {
        let gate = AsyncGate()
        let permissions = ScriptedToolPermissions(gate: gate)
        let tool = calendarTool()
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"])), .response(.say("Dentist at three."))],
            tools: [tool],
            permissions: permissions,
            limits: AgentLimits(totalTimeout: .seconds(10))
        )
        let task = Task { await harness.run() }
        #expect(await waitUntil { permissions.asked.count == 1 })

        // A whole day passes while the person decides; the command's own 10 seconds must not.
        harness.clock.advance(by: .seconds(86_400))
        await settle()
        await gate.open()

        let output = await task.value
        #expect(output.result.outcome == .completed)
        #expect(tool.recorder.count == 1)
    }

    @Test("Esc while the system prompt is up cancels the command")
    func cancelledWhilePrompting() async {
        let gate = AsyncGate()
        let permissions = ScriptedToolPermissions(gate: gate)
        let tool = calendarTool()
        let harness = LoopHarness(
            [.response(.call("calendar_list_events", ["value": "x"]))], tools: [tool], permissions: permissions
        )
        let task = Task { await harness.run() }
        #expect(await waitUntil { permissions.asked.count == 1 })
        task.cancel()
        await gate.open()
        #expect(await task.value.result.outcome == .cancelled)
        #expect(tool.recorder.isEmpty)
    }

    @Test("what already ran before the refusal stays in the conversation's note")
    func earlierWorkIsRemembered() async {
        let permissions = ScriptedToolPermissions([.calendars: .denied])
        let harness = LoopHarness(
            [
                .response(.call("look_up", ["value": "x"], id: "c1")),
                .response(.call("calendar_list_events", ["value": "x"], id: "c2")),
            ],
            tools: [stub("look_up", .readOnly), calendarTool()],
            permissions: permissions
        )
        let output = await harness.run()
        guard case .failed = output.result.outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(output.result.actions == ["Run look_up"])
        let notes = output.memory.messages.compactMap { message -> String? in
            if case .text(let text)? = message.content.first, message.role == .assistant { text } else { nil }
        }
        #expect(notes.last?.contains("Run look_up") == true)
    }
}

/// Collects what happened, in order, from `@Sendable` closures.
private final class OrderLog: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [String]())

    var entries: [String] { store.withLock { $0 } }
    func add(_ entry: String) { store.withLock { $0.append(entry) } }
}
