import CoreGraphics
import Foundation
import os

/// What a screenshot covers.
public enum ScreenScope: String, Sendable, CaseIterable {
    /// The front window of the app in front, and nothing else on the screen.
    case window
    /// The whole display the front window is on.
    case screen
}

public struct ScreenCaptureRequest: Sendable, Equatable {
    public var scope: ScreenScope
    /// The app in front, whose window is captured for `.window`.
    public var app: FrontmostApp?
    /// The longest side of the picture, in pixels. Bigger is sharper and costs more to send.
    public var maxDimension: Int
    /// A particular window of the app to capture, when the caller already knows which. Otherwise its front window is used.
    public var windowID: UInt32?

    public init(
        scope: ScreenScope,
        app: FrontmostApp?,
        maxDimension: Int = ScreenCaptureRequest.defaultMaxDimension,
        windowID: UInt32? = nil
    ) {
        self.scope = scope
        self.app = app
        self.maxDimension = maxDimension
        self.windowID = windowID
    }

    /// Sharp enough to read interface text, small enough to be a few thousand tokens.
    public static let defaultMaxDimension = 1_568
}

/// A finished capture: the picture, and where on the screen it came from, so a point in it can be turned back into a place.
public struct ScreenCapture: Sendable, Equatable {
    public var image: Data
    public var mediaType: String
    /// The picture's size in pixels.
    public var pixelSize: CGSize
    /// The area captured, in points, with the origin at the top left of the main display.
    public var frame: CGRect
    public var windowID: UInt32?
    public var windowTitle: String?
    public var scope: ScreenScope

    public init(
        image: Data,
        mediaType: String,
        pixelSize: CGSize,
        frame: CGRect,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        scope: ScreenScope
    ) {
        self.image = image
        self.mediaType = mediaType
        self.pixelSize = pixelSize
        self.frame = frame
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.scope = scope
    }
}

public protocol ScreenCapturing: Sendable {
    func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture
}

public enum ScreenCaptureError: Error, Sendable, Equatable {
    case noWindow(app: String)
    case permissionDenied
    case failed(String)

    public var message: String {
        switch self {
        case .noWindow(let app):
            "\(app) has no window on the screen to capture. It may be minimized or on another Space."
        case .permissionDenied:
            "Voxa isn't allowed to record the screen. The user can allow it in System Settings → Privacy & Security → Screen Recording."
        case .failed(let reason):
            "The screenshot failed: \(reason)"
        }
    }
}

/// A screenshot Voxa took, remembered so that a later click can point into it.
public struct ScreenshotRecord: Sendable, Equatable {
    public var id: String
    public var app: FrontmostApp
    public var scope: ScreenScope
    public var frame: CGRect
    public var pixelSize: CGSize
    public var windowID: UInt32?

    /// Where a point in the picture is on the screen, in points; nil when the point isn't in the picture.
    public func screenPoint(x: Double, y: Double) -> CGPoint? {
        guard pixelSize.width > 0, pixelSize.height > 0, x >= 0, y >= 0, x <= pixelSize.width, y <= pixelSize.height else { return nil }
        return CGPoint(x: frame.minX + x / pixelSize.width * frame.width, y: frame.minY + y / pixelSize.height * frame.height)
    }
}

/// The last few screenshots, by name (`s1`, `s2`...). Shared by the screenshot tool, which adds to it, and the click tool,
/// which reads from it.
public final class ScreenshotRegistry: @unchecked Sendable {
    private struct State {
        var records: [ScreenshotRecord] = []
        var counter = 0
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public func add(_ capture: ScreenCapture, of app: FrontmostApp) -> ScreenshotRecord {
        state.withLock { state in
            state.counter += 1
            let record = ScreenshotRecord(
                id: "s\(state.counter)",
                app: app,
                scope: capture.scope,
                frame: capture.frame,
                pixelSize: capture.pixelSize,
                windowID: capture.windowID
            )
            state.records.append(record)
            if state.records.count > capacity { state.records.removeFirst(state.records.count - capacity) }
            return record
        }
    }

    public func record(_ id: String) -> ScreenshotRecord? {
        state.withLock { $0.records.first { $0.id == id } }
    }
}
