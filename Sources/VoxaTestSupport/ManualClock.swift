import Foundation
import os

/// A clock whose time only moves when a test says so. Code under test sleeps on it exactly as it would on a real clock;
/// the test calls `advance(by:)` to release the sleepers whose deadline has passed, so timing-dependent behavior
/// (release tails, watchdogs, auto-dismiss) runs instantly and deterministically.
public final class ManualClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration

        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper: Sendable {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now = Instant()
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
    }

    private enum Registration {
        case resumeNow
        case registered
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Number of tasks currently suspended in `sleep`. Lets a test wait until the code under test has reached its sleep.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    if deadline <= state.now { return .resumeNow }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .registered
                }
                switch registration {
                case .resumeNow:
                    continuation.resume()
                case .registered:
                    // Cancelled between the check above and registration: undo it ourselves.
                    if Task.isCancelled {
                        state.withLock { $0.sleepers.removeValue(forKey: id) }?
                            .continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?
                .continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has now passed.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.advanced(by: duration)
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for key in ready.keys {
                state.sleepers.removeValue(forKey: key)
            }
            return ready.values.map(\.continuation)
        }
        for continuation in due {
            continuation.resume()
        }
    }
}
