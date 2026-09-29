import Foundation
import os
import VoxaTools

/// A fixed list of installed apps.
public struct FakeAppCatalog: AppCataloging {
    private let installed: [InstalledApp]

    public init(_ apps: [InstalledApp]) {
        installed = apps
    }

    /// A small, realistic set: system apps, a browser with a two-word name, and an app with a look-alike neighbor.
    public static let standard = FakeAppCatalog([
        app("Safari", "com.apple.Safari", "/Applications/Safari.app"),
        app("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
        app("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
        app("Finder", "com.apple.finder", "/System/Library/CoreServices/Finder.app"),
        app("Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app"),
        app("Visual Studio Code", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app"),
        app("Xcode", "com.apple.dt.Xcode", "/Applications/Xcode.app"),
        app("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
        app("Photo Booth", "com.apple.PhotoBooth", "/System/Applications/Photo Booth.app"),
        app("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app"),
    ])

    public static func app(_ name: String, _ bundleID: String, _ path: String) -> InstalledApp {
        InstalledApp(name: name, bundleID: bundleID, url: URL(fileURLWithPath: path))
    }

    public func apps() -> [InstalledApp] { installed }
}

/// Records what would have been opened.
public final class FakeOpener: AppOpening {
    public enum Opened: Equatable, Sendable {
        case app(String)
        case url(String, in: String?)
    }

    private struct State {
        var opened: [Opened] = []
        var failure: (any Error)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Makes every later call throw this error.
    public var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public var opened: [Opened] { state.withLock { $0.opened } }

    public func open(_ app: InstalledApp) async throws {
        if let failure { throw failure }
        state.withLock { $0.opened.append(.app(app.name)) }
    }

    public func open(_ url: URL, in app: InstalledApp?) async throws {
        if let failure { throw failure }
        state.withLock { $0.opened.append(.url(url.absoluteString, in: app?.name)) }
    }
}

/// Plays back scripted process results and records how it was called.
public final class FakeProcessRunner: ProcessRunning {
    public struct Call: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var standardInput: String?
        public var timeout: Duration
    }

    public typealias Handler = @Sendable (Call) async throws -> ProcessOutput

    private let calls = OSAllocatedUnfairLock(initialState: [Call]())
    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public convenience init(returning output: ProcessOutput) {
        self.init { _ in output }
    }

    public var recorded: [Call] { calls.withLock { $0 } }

    public func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: Duration
    ) async throws -> ProcessOutput {
        let call = Call(
            executable: executable.path,
            arguments: arguments,
            standardInput: standardInput.map { String(bytes: $0, encoding: .utf8) ?? "" },
            timeout: timeout
        )
        calls.withLock { $0.append(call) }
        return try await handler(call)
    }
}
