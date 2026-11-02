import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The data-provider boundary: oriented, bounded PNG data with intrinsic size.
/// No temporary output file, network access, or model loading is required.
public struct QuickLookPreviewContent: Sendable {
    public let data: Data
    public let size: CGSize

    public static func load(url: URL, maxDimension: Int = 1600) throws -> Self {
        let image = try QuickLookRenderer(maxDimension: maxDimension).render(url: url)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw QuickLookRendererError.thumbnailCreationFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw QuickLookRendererError.thumbnailCreationFailed(url)
        }
        return Self(data: data as Data, size: CGSize(width: image.width, height: image.height))
    }
}
