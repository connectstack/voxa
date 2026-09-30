import Testing

/// Makes a whole suite hold `WindowTestLock` while it runs, so suites that put real windows on the screen never overlap.
///
/// All the tests run in one process, and a window's key status, the app's active state and the windows in front are shared by all of
/// them: a Settings test that opens its window in the middle of a test of the Voxa bar takes the keyboard away from it. Put
/// `.windowLock` on each suite that shows a real window, and don't take the lock again inside (it is not reentrant).
public struct WindowLockTrait: SuiteTrait, TestScoping {
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        try await function()
    }
}

extension Trait where Self == WindowLockTrait {
    /// The suite shows real windows: it runs by itself, and never while another such suite does.
    public static var windowLock: Self { Self() }
}
