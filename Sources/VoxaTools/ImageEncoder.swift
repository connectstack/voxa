import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a captured image into bytes a model can take: scaled down to a sensible size, and small enough to send.
enum ImageEncoder {
    /// A screenshot is a few hundred kilobytes as PNG; anything bigger is re-encoded as JPEG rather than sent as it is.
    static let maxBytes = 1_500_000

    struct Encoded {
        var data: Data
        var mediaType: String
        var pixelSize: CGSize
    }

    /// The image scaled so its longest side is at most `maxDimension` pixels (never enlarged), then encoded: PNG when that is
    /// small enough, otherwise JPEG at falling quality, then smaller still.
    static func encode(_ image: CGImage, maxDimension: Int, maxBytes: Int = ImageEncoder.maxBytes) -> Encoded? {
        var current = scaled(image, maxDimension: maxDimension)
        for shrink in [1.0, 0.75, 0.5] {
            if shrink < 1 { current = scaled(current, maxDimension: Int(Double(max(current.width, current.height)) * shrink)) }
            if let png = data(current, type: .png, quality: nil), png.count <= maxBytes {
                return Encoded(data: png, mediaType: "image/png", pixelSize: size(of: current))
            }
            for quality in [0.8, 0.6] {
                if let jpeg = data(current, type: .jpeg, quality: quality), jpeg.count <= maxBytes {
                    return Encoded(data: jpeg, mediaType: "image/jpeg", pixelSize: size(of: current))
                }
            }
        }
        return nil
    }

    static func scaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxDimension > 0, longest > maxDimension else { return image }
        let ratio = Double(maxDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func data(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
