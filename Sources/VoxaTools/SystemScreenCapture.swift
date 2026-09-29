import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The real screenshot, through ScreenCaptureKit.
///
/// A window is captured as itself, not as a region of the screen, so whatever is on top of it (or next to it) never appears in
/// the picture. A whole-display capture leaves Voxa's own windows out. The picture is scaled down before it goes anywhere,
/// and only the bytes are kept: nothing is written to disk.
public struct SystemScreenCapture: ScreenCapturing {
    private let windows: any WindowHitTesting

    public init(windows: any WindowHitTesting = SystemWindowList()) {
        self.windows = windows
    }

    public func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        switch request.scope {
        case .window: return try await captureWindow(of: content, request)
        case .screen: return try await captureDisplay(of: content, request)
        }
    }

    // MARK: A window

    private func captureWindow(of content: SCShareableContent, _ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        guard let app = request.app else { throw ScreenCaptureError.noWindow(app: "The front app") }
        let chosen = request.windowID.flatMap { id in
            content.windows.first { $0.windowID == id && $0.owningApplication?.processID == app.pid && $0.isOnScreen }
        }
        guard let window = chosen ?? Self.frontWindow(of: app.pid, in: content) else { throw ScreenCaptureError.noWindow(app: app.name) }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let image = try await shoot(filter, points: window.frame.size, scale: scale, maxDimension: request.maxDimension)
        // The window server's own bounds, so a point in the picture maps to the same place that clicks and hit tests use.
        let frame = windows.window(withID: window.windowID)?.frame ?? window.frame
        return ScreenCapture(
            image: image.data,
            mediaType: image.mediaType,
            pixelSize: image.pixelSize,
            frame: frame,
            windowID: window.windowID,
            windowTitle: window.title,
            scope: .window
        )
    }

    /// The app's topmost window: the window server knows the stacking order, ScreenCaptureKit only knows the windows. Ordinary
    /// windows, floating panels and alert dialogs count (levels 0 to 8); the menu bar, menu-bar extras, pop-up menus and
    /// overlays sit above that and are not what anyone means by "the window".
    static func frontWindow(of pid: Int32, in content: SCShareableContent) -> SCWindow? {
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && (0...8).contains($0.windowLayer)
                && $0.frame.width >= 50 && $0.frame.height >= 50
        }
        let order = orderedWindowIDs()
        return candidates.min { (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max) }
    }

    /// Window numbers mapped to their place in the stacking order, front first.
    private static func orderedWindowIDs() -> [CGWindowID: Int] {
        let list =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? UInt32 { order[number] = index }
        }
        return order
    }

    // MARK: The whole display

    private func captureDisplay(of content: SCShareableContent, _ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        let front = request.app.flatMap { Self.frontWindow(of: $0.pid, in: content) }
        let display =
            content.displays.first { display in
                front.map { display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } ?? false
            }
            ?? content.displays.first
        guard let display else { throw ScreenCaptureError.failed("There is no display to capture.") }

        // Voxa's own windows (the card, Settings) are left out: the model is shown the user's screen, not Voxa.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let scale = CGFloat(filter.pointPixelScale)
        let image = try await shoot(filter, points: display.frame.size, scale: scale, maxDimension: request.maxDimension)
        return ScreenCapture(
            image: image.data,
            mediaType: image.mediaType,
            pixelSize: image.pixelSize,
            frame: display.frame,
            scope: .screen
        )
    }

    // MARK: Taking and encoding

    private func shoot(
        _ filter: SCContentFilter,
        points: CGSize,
        scale: CGFloat,
        maxDimension: Int
    ) async throws -> ImageEncoder.Encoded {
        let configuration = SCStreamConfiguration()
        let native = CGSize(width: points.width * scale, height: points.height * scale)
        let ratio = min(1, Double(maxDimension) / Double(max(native.width, native.height, 1)))
        configuration.width = max(1, Int((native.width * ratio).rounded()))
        configuration.height = max(1, Int((native.height * ratio).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.map(error)
        }
        guard let encoded = ImageEncoder.encode(image, maxDimension: maxDimension) else {
            throw ScreenCaptureError.failed("The picture could not be encoded.")
        }
        return encoded
    }

    /// "Not allowed" is the one failure a person can fix; the rest are reported as they are.
    static func map(_ error: any Error) -> ScreenCaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue { return .permissionDenied }
        return .failed(nsError.localizedDescription)
    }
}
