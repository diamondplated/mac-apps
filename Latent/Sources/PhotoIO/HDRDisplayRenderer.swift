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
    /// Throws when Core Image cannot encode into the target.
    public func render(_ image: CGImage, to texture: any MTLTexture,
                       commandBuffer: any MTLCommandBuffer, displayHeadroom: Float? = nil) throws {
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
        // Core Image's origin is bottom-left; Metal rows begin at the top.
        // `CIContext.render(_:to: MTLTexture…)` does not pick one answer for
        // that: it writes bottom-up into an ordinary texture but already
        // top-down into a CAMetalLayer drawable, so a manual flip that is
        // right offscreen mirrored every photo on screen (issue #100). An
        // explicit render destination states the row order for every target.
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.isFlipped = true
        destination.colorSpace = colorSpace
        destination.isClamped = false  // keep EDR values above 1.0
        _ = try context.startTask(toRender: scaled, from: target, to: destination, at: .zero)
    }
}
