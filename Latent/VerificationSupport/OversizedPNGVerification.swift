import Foundation
import CoreGraphics
import ImageIO
import PipelineCore
import PhotoIO

/// Shared headless acceptance for the real decoder path, not dimensions alone.
/// This target is linked only by the verifier and tests, never by Latent.app.
public func verifyOversizedPNG() throws {
    guard let url = Bundle.module.url(forResource: "oversized-20000", withExtension: "png"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          info[kCGImagePropertyPixelWidth] as? Int == 20_000,
          info[kCGImagePropertyPixelHeight] as? Int == 20_000 else {
        throw Failure("The synthetic PNG must be a real 20000 by 20000 ImageIO source.")
    }
    do {
        _ = try ImageReader().read(url: url)
        throw Failure("Enhance accepted the 400MP image instead of its memory-limit error.")
    } catch is ImageMemoryPolicy.LimitError {
        // The production limit is at most 2GiB; 400MP needs 11.2GB by policy.
    }
    let budget: UInt64 = 16 * 1024 * 1024
    guard let preview = ImageReader.previewCGImage(url: url, maxWorkingMemoryBytes: budget),
          preview.width > 0, preview.width < 20_000, preview.width == preview.height,
          let pixels = preview.dataProvider?.data, CFDataGetLength(pixels) > 0 else {
        throw Failure("The same valid oversized PNG must still decode a bounded preview.")
    }
    _ = try ImageMemoryPolicy.validate(width: preview.width, height: preview.height, maxBytes: budget)
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
