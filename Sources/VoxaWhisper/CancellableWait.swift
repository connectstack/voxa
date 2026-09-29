import Foundation

/// Waits for work that can't itself be cancelled (a download in the library) but lets the *waiting* be cancelled: when the task
/// is cancelled this throws `CancellationError` at once, and the work finishes in the background with its result dropped. What it
/// had fetched stays on disk, so trying again carries on from there instead of starting over.
func abandoningOnCancel<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let shot = OneShot<T>()
    Task {
        do {
            shot.complete(.success(try await work()))
        } catch {
            shot.complete(.failure(error))
        }
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { shot.install($0) }
    } onCancel: {
        shot.complete(.failure(CancellationError()))
    }
}

/// Delivers one result to one waiter, whichever of "the work finished" and "the wait was cancelled" happens first, and only once.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?

    func install(_ waiter: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            waiter.resume(with: result)
            return
        }
        continuation = waiter
        lock.unlock()
    }

    func complete(_ outcome: Result<T, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }
}
