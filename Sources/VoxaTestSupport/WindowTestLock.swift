import Foundation
import os

/// Lets one test at a time use real windows, the real window list, or the real screen.
///
/// All the tests run in one process, so its windows are shared: a test that asks for "this app's front window" would otherwise
/// find another test's. Every test that needs the real thing takes this first and gives it back when it is done. (Waiting for it
/// is asynchronous, so a test waiting its turn doesn't hold up anything else.)
public final class WindowTestLock: @unchecked Sendable {
    public static let shared = WindowTestLock()

    private struct State {
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public func acquire() async {
        await withCheckedContinuation { continuation in
            let mustWait = state.withLock { state -> Bool in
                if state.isHeld {
                    state.waiters.append(continuation)
                    return true
                }
                state.isHeld = true
                return false
            }
            if !mustWait { continuation.resume() }
        }
    }

    public func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isHeld = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
