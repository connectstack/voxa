import Foundation

/// Polls `condition` until it is true or `timeout` (real time) passes. Tests use it to wait for asynchronous work to
/// settle without sleeping for a fixed time: it returns as soon as the condition holds, and failing tests fail fast
/// with a `false` result instead of hanging.
@MainActor
public func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

extension ManualClock {
    /// Waits until at least `count` tasks are suspended in `sleep`, i.e. the code under test has armed its timers.
    @MainActor
    public func waitForSleepers(atLeast count: Int = 1) async -> Bool {
        await waitUntil { sleeperCount >= count }
    }
}

/// A latch tests use to hold an operation open (a slow permission prompt, a model download) until they release it.
public actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Lets other tasks run: after advancing a `ManualClock`, the sleepers it released are only *scheduled*, and this gives
/// them a moment to execute before the test looks at the result.
public func settle() async {
    try? await Task.sleep(for: .milliseconds(10))
}
