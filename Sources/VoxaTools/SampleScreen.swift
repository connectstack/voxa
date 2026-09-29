import AppKit
import CoreGraphics
import Foundation

/// A screenshot of the pretend desktop: a picture drawn from its elements, so a sample-data run (or a test) sees the whole
/// path, from capture to encoding to a click into the picture, without recording anyone's screen. A control is drawn where
/// the desktop says it is, so a point in the picture lands on the same thing `ui_click` would find there.
public struct SampleScreen: ScreenCapturing {
    private let desktop: SampleDesktop

    /// The whole "display" that a `.screen` capture shows, with the window somewhere on it.
    static let display = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    public init(desktop: SampleDesktop) {
        self.desktop = desktop
    }

    public func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        guard desktop.app != nil else { throw ScreenCaptureError.noWindow(app: "The front app") }
        let covered = request.scope == .window ? desktop.windowFrame : Self.display
        let scale = min(1, Double(request.maxDimension) / Double(max(covered.width, covered.height)))
        let pixels = CGSize(width: (covered.width * scale).rounded(), height: (covered.height * scale).rounded())

        guard let image = draw(covered: covered, scale: scale, pixels: pixels),
            let encoded = ImageEncoder.encode(image, maxDimension: request.maxDimension)
        else { throw ScreenCaptureError.failed("The sample picture could not be drawn.") }
        return ScreenCapture(
            image: encoded.data,
            mediaType: encoded.mediaType,
            pixelSize: encoded.pixelSize,
            frame: covered,
            windowID: request.scope == .window ? SampleDesktop.windowID : nil,
            windowTitle: desktop.node(desktop.window)?.title,
            scope: request.scope
        )
    }

    private func draw(covered: CGRect, scale: Double, pixels: CGSize) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Screen coordinates run down from the top left; the bitmap's run up from the bottom left.
        func rect(_ frame: CGRect) -> NSRect {
            NSRect(
                x: (frame.minX - covered.minX) * scale,
                y: pixels.height - (frame.maxY - covered.minY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
        NSColor(calibratedWhite: covered == desktop.windowFrame ? 0.97 : 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: pixels).fill()
        NSColor.white.setFill()
        rect(desktop.windowFrame).fill()

        var stack = desktop.children(desktop.window)
        while let handle = stack.popLast() {
            stack += desktop.children(handle)
            guard let node = desktop.node(handle), let frame = node.frame else { continue }
            let drawn = rect(frame)
            guard drawn.maxY > 0, drawn.minY < pixels.height else { continue }
            let label = [node.title, node.description, node.value].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let isControl = node.role != "AXStaticText" && node.role != "AXToolbar" && node.role != "AXWebArea"
            if isControl {
                NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
                drawn.fill()
                NSColor(calibratedWhite: 0.6, alpha: 1).setStroke()
                NSBezierPath(rect: drawn).stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, 13 * scale * 1.4)), .foregroundColor: NSColor.black,
            ]
            (node.isSecure ? "••••••••" : label as String).draw(in: drawn.insetBy(dx: 4, dy: 2), withAttributes: attributes)
        }
        return bitmap.cgImage
    }
}
