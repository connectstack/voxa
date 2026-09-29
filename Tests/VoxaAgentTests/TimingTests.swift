import Foundation
import Testing
@testable import VoxaAgent
import VoxaTestSupport

@MainActor
@Suite("Timeouts and the run budget")
struct TimingTests {
    private let clock = ManualClock()

    // MARK: withTimeout

    @Test("an operation that finishes in time returns its value, and its timer is cancelled")
    func finishesInTime() async throws {
        let value = try await withTimeout(.seconds(30), clock: clock) { 42 }
        #expect(value == 42)
    }

    @Test("an operation's own error passes through")
    func propagatesError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTimeout(.seconds(30), clock: clock) { throw Boom() }
        }
    }

    @Test("a slow operation is abandoned when the limit passes, even if it ignores cancellation")
    func abandonsSlowOperation() async {
        let gate = AsyncGate()
        let clock = clock
        let task = Task {
            try await withTimeout(.seconds(5), clock: clock) {
                await gate.wait()   // never cancelled: like a stuck system call
                return 1
            }
        }
        #expect(await clock.waitForSleepers())
        clock.advance(by: .seconds(6))
        await #expect(throws: TimeoutError.self) { try await task.value }
        await gate.open()
    }

    @Test("cancelling the caller returns promptly, without waiting for the operation")
    func cancellation() async {
        let gate = AsyncGate()
        let clock = clock
        let task = Task {
            try await withTimeout(.seconds(30), clock: clock) {
                await gate.wait()
                return 1
            }
        }
        #expect(await clock.waitForSleepers())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open()
    }

    // MARK: RunDeadline

    @Test("the budget expires after the limit of working time")
    func expires() async {
        let deadline = RunDeadline.start(clock: clock, limit: .seconds(10))
        let waiter = Task { try await deadline.waitUntilExpired() }
        #expect(await clock.waitForSleepers())
        clock.advance(by: .seconds(10))
        #expect((try? await waiter.value) != nil, "it returns rather than throwing")
    }

    @Test("time spent paused doesn't count, and time before and after a pause does")
    func pauseStopsTheClock() async {
        let deadline = RunDeadline.start(clock: clock, limit: .seconds(10))
        let expired = OSAllocatedFlag()
        let waiter = Task {
            try await deadline.waitUntilExpired()
            expired.set()
        }
        #expect(await clock.waitForSleepers())

        clock.advance(by: .seconds(4))          // 4 s worked
        await settle()
        await deadline.pause()
        clock.advance(by: .seconds(100))        // a long wait for the user
        await settle()
        #expect(!expired.value, "paused time must not count")
        await deadline.resume()

        #expect(await clock.waitForSleepers())
        clock.advance(by: .seconds(5))          // 9 s worked in all
        await settle()
        #expect(!expired.value)
        clock.advance(by: .seconds(2))          // 11 s worked
        await settle()
        #expect(expired.value)
        waiter.cancel()
    }

    @Test("pausing twice or resuming without a pause is harmless")
    func idempotent() async {
        let deadline = RunDeadline.start(clock: clock, limit: .seconds(10))
        await deadline.resume()
        await deadline.pause()
        await deadline.pause()
        await deadline.resume()
        await deadline.resume()
    }
}

/// A flag a task can set and a test can read.
final class OSAllocatedFlag: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

@Suite("SystemPrompt fallback")
struct SystemPromptFallbackTests {
    @Test("the built-in fallback still carries the step limit and the untrusted-data rule")
    func minimal() {
        let text = SystemPrompt.minimal.render(maxSteps: 7)
        #expect(text.contains("at most 7 tool steps"))
        #expect(text.contains("<untrusted_data>"))
        #expect(!text.contains("{{max_steps}}"))
    }
}
