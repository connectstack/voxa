import Foundation
import os

/// A clipboard that lives in memory, for tests and for sample-data runs.
public final class InMemoryClipboard: ClipboardAccessing, @unchecked Sendable {
    private struct State {
        var content: ClipboardContent
        var writes: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(_ content: ClipboardContent = .empty) {
        state = OSAllocatedUnfairLock(initialState: State(content: content))
    }

    public var content: ClipboardContent {
        get { state.withLock { $0.content } }
        set { state.withLock { $0.content = newValue } }
    }

    /// Everything written, in order.
    public var writes: [String] { state.withLock { $0.writes } }

    public func read() async -> ClipboardContent { content }

    public func write(_ text: String) async {
        state.withLock {
            $0.writes.append(text)
            $0.content = .text(text)
        }
    }
}

/// A frontmost app that is whatever it was told to be, for tests and for sample-data runs.
public final class StaticFrontmostContext: FrontmostContextProviding, FrontmostAppProviding, @unchecked Sendable {
    private let context = OSAllocatedUnfairLock<FrontmostContext?>(initialState: nil)

    public init(_ context: FrontmostContext? = nil) {
        self.context.withLock { $0 = context }
    }

    public var value: FrontmostContext? {
        get { context.withLock { $0 } }
        set { context.withLock { $0 = newValue } }
    }

    public func snapshot() async -> FrontmostContext? { value }

    /// The same app, as the UI tools want to hear about it. There is no process behind it, so its number is made up.
    public func currentApp() -> FrontmostApp? {
        value.map { FrontmostApp(name: $0.appName, bundleID: $0.bundleID, pid: 1) }
    }
}
