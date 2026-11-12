import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Generated photos for burst tests. A "scene" is a seeded composition of
/// coloured shapes with fine detail in the middle; `jitter` nudges it a few
/// pixels and shifts brightness the way consecutive frames of one subject
/// differ, `blur` softens it fully and `softness` (0 to 1) fades a blurred copy over it. No binary fixtures live in the repository.
public enum BurstFixtures {
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    public static let width = 640
    public static let height = 480

    public static func render(scene: Int, jitter: Int = 0, blur: Int = 0, softness: Double = 0) -> CGImage {
        var rng = SplitMix(state: UInt64(truncatingIfNeeded: scene) &* 7919 &+ 17)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        func color() -> CGColor {
            CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1)
        }
        let shift = CGFloat(jitter)
        let bright = 1 - CGFloat(jitter % 3) * 0.01
        // Sky and ground, so different scenes differ in layout and colour.
        let gradient = CGGradient(
            colorsSpace: space, colors: [color(), color()] as CFArray, locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: []
        )
        for _ in 0..<6 {
            let rect = CGRect(
                x: rng.unit() * 480 + shift, y: rng.unit() * 320 + shift * 0.5,
                width: 60 + rng.unit() * 160, height: 60 + rng.unit() * 120
            )
            ctx.setFillColor(color())
            if rng.next() % 2 == 0 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        // Fine detail in the middle: stripes, which only a sharp frame keeps.
        let stripeColor = color()
        ctx.setFillColor(stripeColor)
        var x: CGFloat = 220 + shift
        while x < 420 + shift {
            ctx.fill(CGRect(x: x, y: 150, width: 3, height: 180))
            x += 8
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1 - bright))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var image = ctx.makeImage()!
        if blur > 0 { image = boxBlur(image, radius: blur) }
        if softness > 0 {
            // A partly defocused frame: the sharp image with a blurred copy
            // faded over it. Its feature print stays close to the original's,
            // as a slightly missed focus does in a real burst.
            let soft = boxBlur(image, radius: 1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setAlpha(CGFloat(softness))
            ctx.draw(soft, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = ctx.makeImage()!
        }
        return image
    }

    /// Separable box blur, applied twice, on the RGBA bytes.
    static func boxBlur(_ image: CGImage, radius: Int) -> CGImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func pass(horizontal: Bool) {
            var out = pixels
            let lines = horizontal ? h : w
            let length = horizontal ? w : h
            for line in 0..<lines {
                for i in 0..<length {
                    var sum = [Int](repeating: 0, count: 3)
                    var n = 0
                    for d in -radius...radius {
                        let j = i + d
                        guard j >= 0, j < length else { continue }
                        let idx = horizontal ? (line * w + j) * 4 : (j * w + line) * 4
                        for c in 0..<3 { sum[c] += Int(pixels[idx + c]) }
                        n += 1
                    }
                    let idx = horizontal ? (line * w + i) * 4 : (i * w + line) * 4
                    for c in 0..<3 { out[idx + c] = UInt8(sum[c] / n) }
                }
            }
            pixels = out
        }
        for _ in 0..<2 { pass(horizontal: true); pass(horizontal: false) }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!.makeImage()!
        }
    }

    /// Write a JPEG. `capture` becomes the EXIF original time with
    /// sub-seconds; nil writes none, leaving the file's modification date.
    public static func writeJPEG(_ image: CGImage, to url: URL, capture: Double? = nil) throws {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let capture {
            let whole = floor(capture)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: Date(timeIntervalSince1970: whole)),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", Int((capture - whole) * 100)),
            ]
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
