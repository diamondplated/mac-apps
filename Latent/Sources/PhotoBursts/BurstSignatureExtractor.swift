import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Reads one photo and produces its `PhotoSignature`. This is the only place
/// that touches pixels or Vision; it is synchronous and CPU-heavy, so callers
/// run it on a background task.
public enum BurstSignatureExtractor {
    /// Advance when the sharpness measure or face summary changes meaning, so
    /// cached signatures from older code are recomputed.
    public static let algorithmVersion = 1

    /// Vision and the sharpness measure both read a thumbnail this big. Large
    /// enough for a feature print and face landmarks, small enough that a
    /// 12-megapixel JPEG decodes with ImageIO's subsampling in a few ms.
    static let analysisSize = 512
    /// The luminance image the Laplacian is measured on.
    static let sharpnessSize = 256

    public static var printRevision: Int {
        VNGenerateImageFeaturePrintRequest.currentRevision
    }

    public static func signature(for url: URL) -> PhotoSignature? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let print = featurePrint(of: image) else { return nil }
        return PhotoSignature(
            captureTime: captureTime(source: source, url: url),
            featurePrint: print,
            sharpness: sharpness(of: image),
            faces: faceSummary(of: image)
        )
    }

    // MARK: - Capture time

    static func captureTime(source: CGImageSource, url: URL) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
           let base = exifFormatter.date(from: text) {
            var seconds = base.timeIntervalSince1970
            // Sub-seconds are the digits after the point ("07" means 0.07).
            if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
               let fraction = Double("0." + sub.trimmingCharacters(in: .whitespaces)) {
                seconds += fraction
            }
            return seconds
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Camera clocks have no zone; any fixed zone keeps gaps correct.
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    // MARK: - Likeness

    static func featurePrint(of image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              observation.elementType == .float, observation.elementCount > 0 else { return nil }
        return observation.data
    }

    // MARK: - Sharpness

    /// Variance of the Laplacian over a centre-weighted region of a
    /// downscaled luminance image. Weights are 1 inside the middle half of
    /// each axis and fall off linearly to 0.25 at the border, so the subject
    /// in the middle counts most and a sharp background cannot rescue a
    /// blurred subject.
    public static func sharpness(of image: CGImage) -> Double {
        guard let gray = luminance(of: image, maxSide: sharpnessSize) else { return 0 }
        return laplacianVariance(gray.pixels, width: gray.width, height: gray.height)
    }

    static func luminance(of image: CGImage, maxSide: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(3, Int((Double(image.width) * scale).rounded()))
        let h = max(3, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (pixels, w, h) : nil
    }

    static func laplacianVariance(_ pixels: [UInt8], width w: Int, height h: Int) -> Double {
        guard w >= 3, h >= 3 else { return 0 }
        var weightSum = 0.0
        var mean = 0.0
        var squares = 0.0
        for y in 1..<(h - 1) {
            let wy = axisWeight(Double(y) / Double(h - 1))
            for x in 1..<(w - 1) {
                let c = Int(pixels[y * w + x])
                let lap = Int(pixels[(y - 1) * w + x]) + Int(pixels[(y + 1) * w + x])
                    + Int(pixels[y * w + x - 1]) + Int(pixels[y * w + x + 1]) - 4 * c
                let weight = wy * axisWeight(Double(x) / Double(w - 1))
                let v = Double(lap)
                weightSum += weight
                mean += weight * v
                squares += weight * v * v
            }
        }
        guard weightSum > 0 else { return 0 }
        mean /= weightSum
        return max(0, squares / weightSum - mean * mean)
    }

    /// 1 across the middle half of an axis, 0.25 at the edge.
    private static func axisWeight(_ t: Double) -> Double {
        let d = abs(t - 0.5) * 2          // 0 centre ... 1 edge
        return d <= 0.5 ? 1 : 1 - (d - 0.5) * 1.5
    }

    // MARK: - Faces

    static func faceSummary(of image: CGImage) -> FaceSummary? {
        let quality = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([quality])) != nil,
              let faces = quality.results, !faces.isEmpty else { return nil }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = faces
        _ = try? handler.perform([landmarks])
        let withLandmarks = landmarks.results ?? []
        let meanQuality = faces.reduce(Float(0)) { $0 + ($1.faceCaptureQuality ?? 0) } / Float(faces.count)
        // A face whose eyes cannot be measured counts as open: the claim
        // "eyes closed" needs evidence.
        let allOpen = withLandmarks.allSatisfy { face in
            guard let lm = face.landmarks else { return true }
            return [lm.leftEye, lm.rightEye].allSatisfy { eye in
                guard let eye else { return true }
                return eyeOpenness(eye.normalizedPoints) >= minimumEyeOpenness
            }
        }
        return FaceSummary(count: faces.count, quality: meanQuality, eyesOpen: allOpen)
    }

    /// Height over width of the eye outline. Open eyes sit near 0.3; a
    /// closed eye is a thin line below 0.15.
    static let minimumEyeOpenness: CGFloat = 0.15

    static func eyeOpenness(_ points: [CGPoint]) -> CGFloat {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX > minX else { return 1 }
        return (maxY - minY) / (maxX - minX)
    }
}
