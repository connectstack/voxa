import Foundation
import os
import Testing
import VoxaCore
import VoxaPolicy
@testable import VoxaTools

/// Remembers how long a `wait` was asked to sleep, without sleeping.
private final class Waits: Sendable {
    private let durations = OSAllocatedUnfairLock(initialState: [Duration]())

    var all: [Duration] { durations.withLock { $0 } }

    var tool: WaitTool {
        WaitTool(sleep: { [durations] duration in durations.withLock { $0.append(duration) } })
    }
}

@Suite("wait")
struct WaitToolTests {
    @Test("it waits the number of seconds asked for, 3 if none is given, and says how long it waited")
    func waits() async throws {
        let waits = Waits()
        let tool = waits.tool
        let asked = try await tool.execute(["seconds": 2], context: ToolContext())
        let usual = try await tool.execute([:], context: ToolContext())
        #expect(asked.plainText == "Waited 2 seconds." && asked.provenance == .trusted)
        #expect(usual.plainText == "Waited 3 seconds.")
        #expect(waits.all == [.seconds(2), .seconds(3)])
    }

    @Test("a number outside 1 to 10 is brought back into range, and one second is not 'seconds'")
    func clamped() async throws {
        let waits = Waits()
        let tool = waits.tool
        _ = try await tool.execute(["seconds": 0], context: ToolContext())
        _ = try await tool.execute(["seconds": 99], context: ToolContext())
        let one = try await tool.execute(["seconds": 1], context: ToolContext())
        #expect(waits.all == [.seconds(1), .seconds(10), .seconds(1)])
        #expect(one.plainText == "Waited 1 second.")
    }

    @Test("the schema keeps the model to whole seconds from 1 to 10")
    func schema() {
        let tool = WaitTool()
        #expect(tool.inputSchema["additionalProperties"] == false)
        #expect(InputValidator.validate(["seconds": 5], against: tool.inputSchema).isEmpty)
        #expect(InputValidator.validate([:], against: tool.inputSchema).isEmpty, "seconds is optional")
        for bad: JSONValue in [["seconds": 0], ["seconds": 11], ["seconds": "3"], ["seconds": 2.5], ["minutes": 1]] {
            #expect(!InputValidator.validate(bad, against: tool.inputSchema).isEmpty, "\(bad)")
        }
    }

    @Test("it only passes time, so the policy lets it run without a word, and it needs no permission")
    func policy() throws {
        let tool = WaitTool()
        let assessment = try tool.assess(["seconds": 4])
        #expect(assessment.risk == .readOnly && assessment.title == "Wait 4 seconds" && assessment.block == nil)
        #expect(tool.baselineRisk == .readOnly && tool.requiredPermissions.isEmpty)
        #expect(PolicyFloors.floor(for: "wait") == .readOnly)
        let decision = PolicyEngine().evaluate(
            toolName: tool.name,
            baselineRisk: tool.baselineRisk,
            assessment: assessment,
            taint: RunTaint()
        )
        #expect(decision == .allow)
    }

    @Test("stopping the command stops the wait")
    func cancelled() async {
        let tool = WaitTool(sleep: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await tool.execute(["seconds": 5], context: ToolContext())
        }
    }

    @Test("the real wait really waits, and Esc ends it at once")
    func realSleep() async throws {
        let tool = WaitTool()
        let started = ContinuousClock.now
        let quick = try await tool.execute(["seconds": 1], context: ToolContext())
        #expect(quick.plainText == "Waited 1 second.")
        #expect(ContinuousClock.now - started >= .milliseconds(900), "it did wait")

        let long = Task { try await tool.execute(["seconds": 10], context: ToolContext()) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        long.cancel()
        await #expect(throws: CancellationError.self) { try await long.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(2), "not ten seconds later")
    }
}
