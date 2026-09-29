import Foundation

/// The time budget for one command. It runs down while Voxa works, and **stands still while Voxa waits for the user**: a
/// person deciding whether to allow an action must not have the command time out under them.
actor RunDeadline {
    private let limit: Duration
    private let elapsed: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var pausedTotal: Duration = .zero
    private var pausedAt: Duration?

    init(clock: ErasedClock, limit: Duration) {
        self.limit = limit
        self.elapsed = clock.elapsed
        self.sleep = clock.sleep
    }

    /// Starts a budget on any clock (a real one, or a test's manual one).
    static func start(clock: any Clock<Duration>, limit: Duration) -> RunDeadline {
        RunDeadline(clock: ErasedClock(opening: clock), limit: limit)
    }

    func pause() {
        if pausedAt == nil { pausedAt = elapsed() }
    }

    func resume() {
        guard let start = pausedAt else { return }
        pausedTotal += elapsed() - start
        pausedAt = nil
    }

    /// Time actually spent working.
    private func used() -> Duration {
        let now = elapsed()
        let currentPause = pausedAt.map { now - $0 } ?? .zero
        return now - pausedTotal - currentPause
    }

    /// Returns when the budget is spent. Throws `CancellationError` if the caller stops waiting first.
    func waitUntilExpired() async throws {
        while true {
            let remaining = limit - used()
            if remaining <= .zero { return }
            // While paused nothing is consumed, so this simply wakes and looks again.
            try await sleep(remaining)
        }
    }
}

/// A clock reduced to the two things the agent needs: sleeping, and how long has passed since it was opened. Reading a
/// clock's instants requires knowing its concrete type, so the type is opened once here and hidden behind closures.
struct ErasedClock: Sendable {
    let elapsed: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init(opening clock: any Clock<Duration>) {
        self = Self.open(clock)
    }

    private static func open<C: Clock<Duration>>(_ clock: C) -> ErasedClock {
        let origin = clock.now
        return ErasedClock(elapsed: { origin.duration(to: clock.now) }, sleep: { try await clock.sleep(for: $0) })
    }

    private init(elapsed: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.elapsed = elapsed
        self.sleep = sleep
    }
}

/// Runs `operation` with a time limit, returning as soon as either finishes.
///
/// Unlike a task group, this does not wait for a tool that ignores cancellation: on timeout (or when the caller is
/// cancelled) the operation is asked to stop and then *abandoned*, so a hung tool can't hang the agent with it.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    clock: any Clock<Duration>,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    let work = Task {
        do {
            gate.resume(with: .success(try await operation()))
        } catch {
            gate.resume(with: .failure(error))
        }
    }
    let timer = Task {
        do {
            try await clock.sleep(for: limit)
            gate.resume(with: .failure(TimeoutError()))
        } catch {
            // Cancelled because the operation finished first.
        }
    }
    return try await withTaskCancellationHandler {
        defer { timer.cancel() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
            }
        } catch {
            work.cancel()
            throw error
        }
    } onCancel: {
        work.cancel()
        timer.cancel()
        gate.resume(with: .failure(CancellationError()))
    }
}

struct TimeoutError: Error {}

/// Resumes a continuation exactly once, whichever of several racing tasks gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var early: Result<T, any Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let early {
            done = true
            lock.unlock()
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<T, any Error>) {
        lock.lock()
        guard !done, early == nil else {
            lock.unlock()
            return
        }
        if let continuation {
            done = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
    }
}
