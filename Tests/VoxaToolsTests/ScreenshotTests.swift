import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

private func decode(_ data: Data) -> CGImage? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

/// The colour of one pixel, as 0 to 255 red, green, blue.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
    var bytes = [UInt8](repeating: 0, count: 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: raw.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: info
        ) else { return false }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return true
    }
    return drawn ? (Int(bytes[0]), Int(bytes[1]), Int(bytes[2])) : nil
}

private struct ShotRig {
    let desktop = SampleDesktop.safari()
    let registry = ScreenshotRegistry()
    let tool: ScreenshotTool
    let ui: AccessibilityAutomation

    init(capturer: (any ScreenCapturing)? = nil) {
        tool = ScreenshotTool(capturer: capturer ?? SampleScreen(desktop: desktop), apps: desktop, registry: registry)
        var limits = AccessibilityAutomation.Limits()
        limits.settleDelay = .zero
        ui = AccessibilityAutomation(
            tree: desktop, input: desktop, windows: desktop, frontmost: desktop, screenshots: registry, limits: limits)
    }
}

private struct FailingCapture: ScreenCapturing {
    var error: ScreenCaptureError
    func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture { throw error }
}

@Suite("screenshot")
struct ScreenshotToolTests {
    @Test("it returns a picture and a line about it, as untrusted data, and remembers where the picture came from")
    func takes() async throws {
        let rig = ShotRig()
        let result = try await rig.tool.execute([:], context: ToolContext())
        #expect(!result.isError)
        #expect(result.provenance == .untrusted(source: "the screen"))
        #expect(result.notice == "Looked at Safari")

        let text = result.plainText
        #expect(text.hasPrefix("Screenshot s1 of Safari's window: "))
        guard case .image(let data, let mediaType)? = result.content.last else {
            Issue.record("the last part should be the picture")
            return
        }
        #expect(mediaType == "image/png")
        let image = try #require(decode(data))
        #expect(max(image.width, image.height) <= ScreenCaptureRequest.defaultMaxDimension)

        let record = try #require(rig.registry.record("s1"))
        #expect(record.app.name == "Safari" && record.scope == .window)
        #expect(record.frame == rig.desktop.windowFrame)
        #expect(Int(record.pixelSize.width) == image.width && Int(record.pixelSize.height) == image.height)
        #expect(text.contains("\(image.width) by \(image.height) pixels"))
    }

    @Test("the picture shows the window's controls where they are, and a point in it can be clicked")
    func clicksIntoIt() async throws {
        let rig = ShotRig()
        let result = try await rig.tool.execute([:], context: ToolContext())
        guard case .image(let data, _)? = result.content.last, let image = decode(data) else {
            Issue.record("no picture")
            return
        }
        let record = try #require(rig.registry.record("s1"))
        // "Send Feedback" spans x 140 to 280 and y 350 to 380 on the screen; find its middle in the picture.
        let scale = Double(image.width) / rig.desktop.windowFrame.width
        let x = (210 - rig.desktop.windowFrame.minX) * scale
        let y = (365 - rig.desktop.windowFrame.minY) * scale
        let middle = try #require(pixel(image, x: Int(x), y: Int(y)))
        let page = try #require(pixel(image, x: Int(20 * scale), y: Int(600 * scale)))
        #expect(middle != page, "the button is drawn differently from the empty page around it")

        // The point in the picture is the point on the screen, and it is the button.
        let described = try rig.ui.describe(.screenshotPoint(id: record.id, x: x, y: y))
        #expect(described.label == "Send Feedback")
        _ = try await rig.ui.click(.screenshotPoint(id: record.id, x: x, y: y), button: .left, clickCount: 1)
        #expect(rig.desktop.log == ["click:210,365:left:1"])
    }

    @Test("a picture of one window is a notice, asks after outside content, and names what it shows")
    func windowPolicy() throws {
        let rig = ShotRig()
        let assessment = try rig.tool.assess([:])
        #expect(assessment.risk == .reversible)
        #expect(assessment.title == "Look at the Safari window")
        #expect(assessment.reasons.contains { $0.contains("sent to the model") })
        #expect(
            PolicyEngine().evaluate(toolName: "screenshot", baselineRisk: .reversible, assessment: assessment, taint: RunTaint())
                == .allowWithNotice(assessment.title))

        var taint = RunTaint()
        taint.absorb(.text("x", provenance: .untrusted(source: "the app's window")))
        guard
            case .requireConfirmation = PolicyEngine().evaluate(
                toolName: "screenshot", baselineRisk: .reversible, assessment: assessment, taint: taint)
        else {
            Issue.record("should ask once outside content has been read")
            return
        }
        #expect(PolicyFloors.floor(for: "screenshot") == .reversible)
    }

    @Test("a picture of the whole screen always asks, and says what it would show")
    func screenPolicy() throws {
        let rig = ShotRig()
        let assessment = try rig.tool.assess(["scope": "screen"])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.title == "Look at the whole screen")
        #expect(assessment.reasons.contains { $0.contains("everything on your screen") })
        guard
            case .requireConfirmation(let prompt) = PolicyEngine().evaluate(
                toolName: "screenshot", baselineRisk: .reversible, assessment: assessment, taint: RunTaint())
        else {
            Issue.record("should always ask")
            return
        }
        #expect(prompt.risk == .sensitive)
    }

    @Test("the whole screen can be captured too, and covers the display rather than the window")
    func screenScope() async throws {
        let rig = ShotRig()
        let result = try await rig.tool.execute(["scope": "screen"], context: ToolContext())
        #expect(result.plainText.hasPrefix("Screenshot s1 of the whole screen: "))
        let record = try #require(rig.registry.record("s1"))
        #expect(record.scope == .screen && record.frame == SampleScreen.display)
        #expect(result.notice == "Looked at the screen")
    }

    @Test("a password manager is never captured, and the reason is given")
    func restricted() async throws {
        let rig = ShotRig()
        rig.desktop.app = FrontmostApp(name: "1Password", bundleID: "com.1password.1password", pid: SampleDesktop.safariPID)
        let assessment = try rig.tool.assess([:])
        #expect(assessment.block?.contains("Voxa doesn't look at 1Password") == true)
        // Even the whole screen is refused while such an app is in front, because it would be in the picture.
        #expect(try rig.tool.assess(["scope": "screen"]).block != nil)
        let result = try await rig.tool.execute([:], context: ToolContext())
        #expect(result.isError && rig.registry.record("s1") == nil)
    }

    @Test("with no app in front there is no window to look at, but the whole screen can still be shown")
    func noApp() async throws {
        let rig = ShotRig()
        rig.desktop.app = nil
        #expect(throws: ToolInputError.self) { try rig.tool.assess([:]) }
        let result = try await rig.tool.execute([:], context: ToolContext())
        #expect(result.isError && result.plainText == "No app is in front.")
        #expect(try rig.tool.assess(["scope": "screen"]).risk == .sensitive)
    }

    @Test("a refused permission or a failed capture is an error the model can relay, never a crash")
    func failures() async throws {
        let denied = ShotRig(capturer: FailingCapture(error: .permissionDenied))
        let result = try await denied.tool.execute([:], context: ToolContext())
        #expect(result.isError && result.plainText.contains("Screen Recording") && result.provenance == .trusted)
        let missing = ShotRig(capturer: FailingCapture(error: .noWindow(app: "Safari")))
        #expect(try await missing.tool.execute([:], context: ToolContext()).plainText.contains("no window on the screen"))
        #expect(missing.registry.record("s1") == nil)
    }

    @Test("the last few pictures are kept, and older ones are forgotten")
    func registryCapacity() throws {
        let registry = ScreenshotRegistry(capacity: 3)
        let app = FrontmostApp(name: "Safari", pid: 1)
        let capture = ScreenCapture(
            image: Data(), mediaType: "image/png", pixelSize: CGSize(width: 10, height: 10), frame: .zero, scope: .window)
        let ids = (0..<5).map { _ in registry.add(capture, of: app).id }
        #expect(ids == ["s1", "s2", "s3", "s4", "s5"])
        #expect(registry.record("s1") == nil && registry.record("s2") == nil)
        #expect(registry.record("s3") != nil && registry.record("s5") != nil)
    }

    @Test("a point in a picture maps onto the area it covers, and outside it maps nowhere")
    func mapping() {
        let record = ScreenshotRecord(
            id: "s1",
            app: FrontmostApp(name: "A", pid: 1),
            scope: .window,
            frame: CGRect(x: 100, y: 50, width: 800, height: 400),
            pixelSize: CGSize(width: 400, height: 200),
            windowID: nil
        )
        #expect(record.screenPoint(x: 0, y: 0) == CGPoint(x: 100, y: 50))
        #expect(record.screenPoint(x: 200, y: 100) == CGPoint(x: 500, y: 250))
        #expect(record.screenPoint(x: 400, y: 200) == CGPoint(x: 900, y: 450))
        #expect(
            record.screenPoint(x: 401, y: 10) == nil && record.screenPoint(x: -1, y: 10) == nil
                && record.screenPoint(x: 10, y: 201) == nil)
    }
}

@Suite("Image encoding")
struct ImageEncoderTests {
    private func bitmap(width: Int, height: Int, noise: Bool) throws -> CGImage {
        var bytes = [UInt8](repeating: 200, count: width * height * 4)
        if noise {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        return try #require(image)
    }

    @Test("a big picture is scaled down to fit, keeping its shape; a small one is left alone")
    func scaling() throws {
        let big = try #require(ImageEncoder.encode(try bitmap(width: 3_000, height: 2_000, noise: false), maxDimension: 1_568))
        #expect(big.pixelSize == CGSize(width: 1_568, height: 1_045))
        #expect(big.mediaType == "image/png")
        let small = try #require(ImageEncoder.encode(try bitmap(width: 400, height: 300, noise: false), maxDimension: 1_568))
        #expect(small.pixelSize == CGSize(width: 400, height: 300), "never enlarged")
    }

    @Test("a picture too detailed for PNG to be small is sent as JPEG, within the limit")
    func jpegFallback() throws {
        let encoded = try #require(
            ImageEncoder.encode(try bitmap(width: 1_400, height: 900, noise: true), maxDimension: 1_568, maxBytes: 600_000))
        #expect(encoded.mediaType == "image/jpeg")
        #expect(encoded.data.count <= 600_000)
        #expect(decode(encoded.data) != nil)
    }

    @Test("what comes out is a picture that can be read back at the size reported")
    func roundTrip() throws {
        let encoded = try #require(ImageEncoder.encode(try bitmap(width: 800, height: 500, noise: false), maxDimension: 1_568))
        let image = try #require(decode(encoded.data))
        #expect(CGSize(width: image.width, height: image.height) == encoded.pixelSize)
    }
}

/// The real ScreenCaptureKit path, on a window of this test's own, so that no other window is ever in the picture. It needs
/// Screen Recording access for the process running the tests, and is skipped without it.
@Suite(
    "Real screen capture",
    .serialized,
    .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0 && CGPreflightScreenCaptureAccess())
)
@MainActor
struct RealScreenCaptureTests {
    @Test("a window is captured as itself, at the size it has, with its own colours, and nothing around it")
    func capturesOwnWindow() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        _ = NSApplication.shared
        let frame = NSRect(x: 260, y: 260, width: 360, height: 220)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = NSColor(calibratedRed: 1, green: 0, blue: 1, alpha: 1)  // magenta
        window.isOpaque = true
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))

        let app = FrontmostApp(name: "Voxa tests", pid: getpid())
        let capture = try await SystemScreenCapture().capture(
            ScreenCaptureRequest(scope: .window, app: app, windowID: UInt32(window.windowNumber))
        )
        #expect(capture.scope == .window && capture.windowID == UInt32(window.windowNumber))

        let image = try #require(decode(capture.image))
        #expect(CGSize(width: image.width, height: image.height) == capture.pixelSize)
        // The picture has the window's shape, and the window's magenta (as the display shows it) at its middle and near the corners.
        #expect(abs(Double(image.width) / Double(image.height) - 360.0 / 220.0) < 0.05)
        for (x, y) in [(image.width / 2, image.height / 2), (4, 4), (image.width - 5, image.height - 5)] {
            let color = try #require(pixel(image, x: x, y: y))
            #expect(color.red > 230 && color.green < 100 && color.blue > 230, "pixel (\(x), \(y)) was \(color)")
        }
        // The frame is where the window server puts the window, so a point in the picture maps to the right place on the screen.
        let reported = try #require(SystemWindowList().window(withID: UInt32(window.windowNumber)))
        #expect(capture.frame == reported.frame)
    }

    @Test("an app with no window on the screen is reported, not guessed at")
    func noWindow() async {
        do {
            _ = try await SystemScreenCapture().capture(
                ScreenCaptureRequest(scope: .window, app: FrontmostApp(name: "Nothing", pid: 1)))
            Issue.record("there is no such window to capture")
        } catch let error as ScreenCaptureError {
            #expect(error == .noWindow(app: "Nothing"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
