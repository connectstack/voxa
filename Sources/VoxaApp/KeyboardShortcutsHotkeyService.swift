import AppKit
import KeyboardShortcuts
import Observation
import VoxaCore
import VoxaSettings

/// `HotkeyService` backed by the KeyboardShortcuts package (Carbon hot keys).
///
/// This is deliberately a thin pass-through: events are forwarded exactly as the system delivers them. Tolerating a
/// duplicate or missing event is the session controller's job, because it owns the state that decides what a stray
/// event means (it ignores a press while a command is running, and a release with nothing running).
///
/// There is intentionally **no key-state polling**. An earlier version polled `CGEventSource.keyState` to synthesize a
/// missing key-up, but without Input Monitoring permission macOS reports every key as up, so the "watchdog" ended
/// every hold about 100 ms after the press. Esc is only registered as a global shortcut while a session is consuming
/// `cancelKeyPresses()`.
@MainActor
@Observable
public final class KeyboardShortcutsHotkeyService: HotkeyService {
    /// Kept in sync with the recorder in Settings so menus and the HUD always show the current shortcut.
    public private(set) var pushToTalkDescription: String?
    /// The same for the shortcut that opens the Voxa bar.
    public private(set) var openBarDescription: String?

    @ObservationIgnored public let pushToTalk: AsyncStream<PushToTalkEvent>
    @ObservationIgnored private let continuation: AsyncStream<PushToTalkEvent>.Continuation
    @ObservationIgnored public let openBarPresses: AsyncStream<Void>
    @ObservationIgnored private let openBarContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var openBarListener: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var shortcutObserver: (any NSObjectProtocol)?
    #if DEBUG
    /// Listeners for keys injected from a shell (see DebugHooks), alongside the real Carbon shortcuts.
    @ObservationIgnored private var debugEscape: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var debugReturn: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif

    public init() {
        let (stream, continuation) = AsyncStream<PushToTalkEvent>.makeStream()
        self.pushToTalk = stream
        self.continuation = continuation
        let (opens, opensContinuation) = AsyncStream<Void>.makeStream()
        self.openBarPresses = opens
        self.openBarContinuation = opensContinuation
        self.pushToTalkDescription = Self.currentDescription()
        self.openBarDescription = Self.currentDescription(for: .openBar)
    }

    /// Begins listening. Call once at launch.
    public func start() {
        guard listener == nil else { return }

        let events = KeyboardShortcuts.events(for: .pushToTalk)
        listener = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }

        let opens = KeyboardShortcuts.events(.keyDown, for: .openBar)
        openBarListener = Task { [weak self] in
            for await _ in opens {
                Log.hotkey.notice("open-the-bar key down")
                self?.openBarContinuation.yield()
            }
        }

        // KeyboardShortcuts posts this notification whenever a named shortcut changes. The name is an implementation
        // detail of the package; if it ever changes, the only effect is that the label refreshes on next launch.
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushToTalkDescription = Self.currentDescription()
                self?.openBarDescription = Self.currentDescription(for: .openBar)
            }
        }
        pushToTalkDescription = Self.currentDescription()
        openBarDescription = Self.currentDescription(for: .openBar)
        Log.hotkey.notice("push-to-talk shortcut registered")
    }

    public func cancelKeyPresses() -> AsyncStream<Void> {
        let presses = KeyboardShortcuts.events(.keyDown, for: KeyboardShortcuts.Shortcut(.escape))
        return AsyncStream { continuation in
            let forwarder = Task {
                for await _ in presses {
                    continuation.yield()
                }
                continuation.finish()
            }
            #if DEBUG
            let id = UUID()
            debugEscape[id] = continuation
            #endif
            // Ending the inner sequence is what makes KeyboardShortcuts unregister Esc.
            continuation.onTermination = { [weak self] _ in
                forwarder.cancel()
                #if DEBUG
                Task { @MainActor in self?.debugEscape[id] = nil }
                #endif
            }
        }
    }

    public func allowKeyPresses() -> AsyncStream<Void> {
        let presses = KeyboardShortcuts.events(.keyDown, for: KeyboardShortcuts.Shortcut(.return, modifiers: .command))
        return AsyncStream { continuation in
            let forwarder = Task {
                for await _ in presses {
                    continuation.yield()
                }
                continuation.finish()
            }
            #if DEBUG
            let id = UUID()
            debugReturn[id] = continuation
            #endif
            continuation.onTermination = { [weak self] _ in
                forwarder.cancel()
                #if DEBUG
                Task { @MainActor in self?.debugReturn[id] = nil }
                #endif
            }
        }
    }

    #if DEBUG
    /// Delivers Esc / ⌘Return to whoever is listening, as the Carbon shortcut would. Debug builds only.
    func debugPressEscape() { debugEscape.values.forEach { $0.yield() } }
    func debugPressAllow() { debugReturn.values.forEach { $0.yield() } }
    /// How many listeners are registered right now (a listener exists exactly while its key is captured).
    var debugListenerCounts: (escape: Int, allowKey: Int) { (debugEscape.count, debugReturn.count) }
    #endif

    // MARK: Events

    func handle(_ event: KeyboardShortcuts.EventType) {
        switch event {
        case .keyDown:
            // The breadcrumbs carry no user content, so they are safe at the default (persisted) level and make a
            // "the shortcut does nothing" report diagnosable from `log show`.
            Log.hotkey.notice("push-to-talk key down")
            continuation.yield(.pressed)
        case .keyUp:
            Log.hotkey.notice("push-to-talk key up")
            continuation.yield(.released)
        }
    }

    private static func currentDescription(for name: KeyboardShortcuts.Name = .pushToTalk) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
