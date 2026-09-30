import Foundation
import VoxaCore
import VoxaHUD
import VoxaPermissions

/// Records everything the session asks the HUD to do.
@MainActor
public final class FakeHUD: HUDPresenting {
    public enum Event: Equatable {
        case beginSession
        case show(HUDMode)
        case transcript(String, isFinal: Bool)
        case hide(after: Duration?)
        case keysEnabled(Bool)
        case answerStatus(AnswerStatus)
    }

    public private(set) var events: [Event] = []
    public private(set) var levelCount = 0
    public var hotkeyHint: String?
    public var onRecovery: ((RecoveryAction) -> Void)?
    public var onConfirmationChoice: ((ConfirmationChoice) -> Void)?

    public init() {}

    /// Every mode passed to `show`, in order.
    public var modes: [HUDMode] {
        events.compactMap { if case .show(let mode) = $0 { mode } else { nil } }
    }

    public var lastMode: HUDMode? { modes.last }
    public var beginCount: Int { events.filter { $0 == .beginSession }.count }

    /// Whether the most recent hide request was immediate and nothing was shown after it.
    public var isDismissed: Bool {
        guard let lastHide = events.lastIndex(of: .hide(after: nil)) else { return false }
        return !events[lastHide...].contains { if case .show = $0 { true } else { false } }
    }

    public func beginSession() { events.append(.beginSession) }
    public func show(_ mode: HUDMode) { events.append(.show(mode)) }
    public func setTranscript(_ text: String, isFinal: Bool) { events.append(.transcript(text, isFinal: isFinal)) }
    public func push(level: AudioLevel) { levelCount += 1 }
    public func hide(after delay: Duration?) { events.append(.hide(after: delay)) }
    public func setConfirmationKeysEnabled(_ enabled: Bool) { events.append(.keysEnabled(enabled)) }
    public func setAnswerStatus(_ status: AnswerStatus) { events.append(.answerStatus(status)) }

    /// The state of the keyboard answer the last time it was set.
    public var keysEnabled: Bool {
        for event in events.reversed() {
            if case .keysEnabled(let enabled) = event { return enabled }
        }
        return false
    }

    public var lastAnswerStatus: AnswerStatus? {
        for event in events.reversed() {
            if case .answerStatus(let status) = event { return status }
        }
        return nil
    }
}

/// Permissions that are granted (or not) as the test dictates.
@MainActor
public final class FakePermissions: PermissionsProviding {
    public var statuses: [PermissionKind: PermissionStatus] = [:]
    /// What a prompt resolves to.
    public var grantOnRequest = true
    /// Runs while a prompt is "showing"; lets a test hold the request open.
    public var whileRequesting: (@MainActor () async -> Void)?
    public private(set) var requested: [PermissionKind] = []
    public private(set) var openedSettings: [PermissionKind] = []

    public init() {}

    public func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .granted
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        requested.append(kind)
        await whileRequesting?()
        let result: PermissionStatus = grantOnRequest ? .granted : .denied
        statuses[kind] = result
        return result
    }

    public func openSystemSettings(for kind: PermissionKind) {
        openedSettings.append(kind)
    }
}

@MainActor
public final class FakeSettings: SettingsProviding {
    public var current: AppSettings

    public init(_ settings: AppSettings = AppSettings(speechEngine: .appleAutomatic, localeIdentifier: "en_US")) {
        current = settings
    }
}

/// A hotkey service the test presses by hand.
@MainActor
public final class FakeHotkeyService: HotkeyService {
    public let pushToTalk: AsyncStream<PushToTalkEvent>
    public let openBarPresses: AsyncStream<Void>
    public var pushToTalkDescription: String? = "⌥Space"
    /// How many Esc listeners are registered right now (Esc must only be captured while a session needs it).
    public private(set) var activeCancelListeners = 0
    /// How many ⌘Return listeners are registered right now (the chord must only be captured while a confirmation needs it).
    public private(set) var activeAllowListeners = 0

    private let continuation: AsyncStream<PushToTalkEvent>.Continuation
    private let openBarContinuation: AsyncStream<Void>.Continuation
    private var cancelContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var allowContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {
        (pushToTalk, continuation) = AsyncStream<PushToTalkEvent>.makeStream()
        (openBarPresses, openBarContinuation) = AsyncStream<Void>.makeStream()
    }

    /// The shortcut that opens the Voxa bar is pressed.
    public func pressOpenBar() { openBarContinuation.yield() }

    public func press() { continuation.yield(.pressed) }
    public func release() { continuation.yield(.released) }

    public func pressEscape() {
        for continuation in cancelContinuations.values {
            continuation.yield()
        }
    }

    public func pressAllow() {
        for continuation in allowContinuations.values {
            continuation.yield()
        }
    }

    public func allowKeyPresses() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            allowContinuations[id] = continuation
            activeAllowListeners += 1
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.allowContinuations.removeValue(forKey: id) != nil else { return }
                    self.activeAllowListeners -= 1
                }
            }
        }
    }

    public func cancelKeyPresses() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            cancelContinuations[id] = continuation
            activeCancelListeners += 1
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.cancelContinuations.removeValue(forKey: id) != nil else { return }
                    self.activeCancelListeners -= 1
                }
            }
        }
    }
}
