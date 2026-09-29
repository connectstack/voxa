import AppKit
import ApplicationServices
import Foundation
import os
import VoxaCore

/// Remembers the app that was in front before Voxa took focus. Voxa's own windows (Settings, a permission prompt) make Voxa
/// the frontmost app, and then "what's in front" should still mean the app the user was working in.
@MainActor
final class FrontmostAppTracker {
    struct App: Sendable, Equatable {
        var name: String
        var bundleID: String?
        var pid: pid_t
    }

    private var lastOther: App?
    /// Kept only so the observations live as long as the tracker, which is as long as the app.
    private var observers: [any NSObjectProtocol] = []
    private let ownBundleID = Bundle.main.bundleIdentifier
    /// Told the app in front whenever it changes, so that a tool can ask for it from anywhere without waiting for the main actor.
    private let publish: @Sendable (FrontmostApp?) -> Void

    init(publish: @escaping @Sendable (FrontmostApp?) -> Void) {
        self.publish = publish
        lastOther = Self.snapshot(NSWorkspace.shared.frontmostApplication).flatMap { isVoxa($0) ? nil : $0 }
        publish(lastOther.map(Self.published))

        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication).flatMap(Self.snapshot)
                MainActor.assumeIsolated {
                    guard let self, let app, !self.isVoxa(app) else { return }
                    self.lastOther = app
                    self.publish(Self.published(app))
                }
            }
        )
        // An app that has quit is no longer "the app in front".
        observers.append(
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, let pid, self.lastOther?.pid == pid else { return }
                    self.lastOther = nil
                    self.publish(nil)
                }
            }
        )
    }

    private nonisolated static func published(_ app: App) -> FrontmostApp {
        FrontmostApp(name: app.name, bundleID: app.bundleID, pid: app.pid)
    }

    /// The app in front, or the last one that was if Voxa itself is.
    func current() -> App? {
        if let front = Self.snapshot(NSWorkspace.shared.frontmostApplication) {
            if !isVoxa(front) { lastOther = front } else { return lastOther }
            return front
        }
        return lastOther
    }

    private func isVoxa(_ app: App) -> Bool {
        app.pid == ProcessInfo.processInfo.processIdentifier || (ownBundleID != nil && app.bundleID == ownBundleID)
    }

    private nonisolated static func snapshot(_ app: NSRunningApplication?) -> App? {
        guard let app else { return nil }
        return App(
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
            bundleID: app.bundleIdentifier,
            pid: app.processIdentifier
        )
    }
}

/// The real thing: the app in front, and with Accessibility granted, its window title and the text selected in it.
public final class SystemFrontmostContext: FrontmostContextProviding, FrontmostAppProviding, @unchecked Sendable {
    /// The app in front as of the last change, readable from anywhere without a hop to the main actor.
    private let latest = OSAllocatedUnfairLock<FrontmostApp?>(initialState: nil)
    /// Made on first use, on the main actor, so creating this type never needs the main actor.
    private let tracker: TrackerBox

    public init() {
        let latest = latest
        tracker = TrackerBox { app in latest.withLock { $0 = app } }
    }

    /// Starts following which app is in front. Call once at launch, on the main actor.
    @MainActor
    public func start() {
        tracker.startIfNeeded()
    }

    /// The app in front, as last seen. Nil until `start()` has run.
    public func currentApp() -> FrontmostApp? {
        latest.withLock { $0 }
    }

    public func snapshot() async -> FrontmostContext? {
        guard let app = await MainActor.run(body: { tracker.current() }) else { return nil }
        guard AXIsProcessTrusted() else {
            return FrontmostContext(appName: app.name, bundleID: app.bundleID, accessibilityGranted: false)
        }
        // Accessibility calls are IPC to the other app and can stall if it is busy, so they run off the main thread.
        let details = await Task.detached { AccessibilityReader.read(pid: app.pid) }.value
        return FrontmostContext(
            appName: app.name,
            bundleID: app.bundleID,
            windowTitle: details.title,
            selectedText: details.selection,
            accessibilityGranted: true
        )
    }
}

/// Holds the main-actor tracker for a type that isn't itself main-actor bound.
private final class TrackerBox: @unchecked Sendable {
    @MainActor private var tracker: FrontmostAppTracker?
    private let publish: @Sendable (FrontmostApp?) -> Void

    init(publish: @escaping @Sendable (FrontmostApp?) -> Void) {
        self.publish = publish
    }

    @MainActor
    func startIfNeeded() {
        if tracker == nil { tracker = FrontmostAppTracker(publish: publish) }
    }

    @MainActor
    func current() -> FrontmostAppTracker.App? {
        startIfNeeded()
        return tracker?.current()
    }
}

/// Reads an app's front window title and selected text through the Accessibility API.
enum AccessibilityReader {
    /// A stuck app must not stall a command: each call gives up after this long.
    static let messagingTimeout: Float = 1.0

    static func read(pid: pid_t) -> (title: String?, selection: String?) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var title: String?
        if let window = element(application, kAXFocusedWindowAttribute) {
            title = string(window, kAXTitleAttribute)
        }
        var selection: String?
        if let focused = element(application, kAXFocusedUIElementAttribute), !isSecureField(focused) {
            selection = string(focused, kAXSelectedTextAttribute)
        }
        return (title.flatMap { $0.isEmpty ? nil : $0 }, selection.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // The type was just checked, so the cast cannot fail.
        return (value as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// A password field never gives up its contents, and Voxa doesn't try.
    private static func isSecureField(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == "AXSecureTextField" || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }
}
