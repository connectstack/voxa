#!/usr/bin/env swift
// Generates Voxa's app icon (App/Assets.xcassets/AppIcon.appiconset) from code, so the artwork is reproducible and
// reviewable: a violet squircle with a white voice waveform.
//
//   swift scripts/make-icon.swift

import AppKit

let designSize: CGFloat = 1024

func drawIcon(into context: NSGraphicsContext, pixels: CGFloat) {
    let cg = context.cgContext
    cg.scaleBy(x: pixels / designSize, y: pixels / designSize)

    // The macOS icon grid: an 824-point body inside a 1024-point canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Body with a soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.90, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Violet gradient, lighter at the top.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.55, green: 0.47, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.27, green: 0.20, blue: 0.82, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -90)

    // A faint highlight along the top edge.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The waveform: five rounded bars, tallest in the middle.
    let heights: [CGFloat] = [0.20, 0.40, 0.60, 0.40, 0.20].map { $0 * body.height }
    let barWidth: CGFloat = 70
    let gap: CGFloat = 46
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - totalWidth / 2

    NSGraphicsContext.saveGraphicsState()
    let barShadow = NSShadow()
    barShadow.shadowOffset = NSSize(width: 0, height: -8)
    barShadow.shadowBlurRadius = 18
    barShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    barShadow.set()
    NSColor.white.setFill()
    for height in heights {
        let bar = NSRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
}

func renderPNG(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    drawIcon(into: context, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

// (point size, scale) pairs required for a macOS app icon.
let variants: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for variant in variants {
    let pixels = variant.points * variant.scale
    let name = "icon_\(variant.points)x\(variant.points)" + (variant.scale == 2 ? "@2x" : "") + ".png"
    guard let png = renderPNG(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconSet.appendingPathComponent(name))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(variant.scale)x",
        "size": "\(variant.points)x\(variant.points)",
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("wrote \(variants.count) icon images to \(iconSet.path)")
