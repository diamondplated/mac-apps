import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Floating-point display rendering shared by the EDR view and offscreen tests.
/// It never changes enhancement/export pixels or opens a window.
@MainActor
public final class HDRDisplayRenderer {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let colorSpace: CGColorSpace
    private let context: CIContext

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        self.device = device
        self.commandQueue = queue
        self.colorSpace = space
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: space, .workingFormat: CIFormat.RGBAh.rawValue,
            .cacheIntermediates: false,
        ])
    }

    /// Render to a floating-point target. Caller owns command-buffer completion
    /// and presentation, permitting tests to read back without a CAMetalLayer.
    public func render(_ image: CGImage, to texture: any MTLTexture,
                       commandBuffer: any MTLCommandBuffer, displayHeadroom: Float? = nil) {
        var source = CIImage(cgImage: image)
        if let headroom = displayHeadroom {
            if #available(macOS 26.0, *) {
                let toneMap = CIFilter.systemToneMap()
                toneMap.inputImage = source
                toneMap.displayHeadroom = max(1, headroom)
                source = toneMap.outputImage ?? source
            } else if #available(macOS 15.0, *), image.contentHeadroom > 1 {
                let toneMap = CIFilter.toneMapHeadroom()
                toneMap.inputImage = source
                toneMap.sourceHeadroom = image.contentHeadroom
                toneMap.targetHeadroom = max(1, headroom)
                source = toneMap.outputImage ?? source
            }
        }
        let target = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let scaled = source.transformed(by: CGAffineTransform(
            scaleX: target.width / source.extent.width,
            y: target.height / source.extent.height
        ))
        // Core Image's origin is bottom-left; Metal drawable rows begin at
        // the top. Flip exactly once so CGImage row order and EXIF orientation
        // survive presentation (also asserted by the asymmetric pixel fixture).
        let displayImage = scaled
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: target.height))
        context.render(displayImage, to: texture, commandBuffer: commandBuffer,
                       bounds: target, colorSpace: colorSpace)
    }
}
