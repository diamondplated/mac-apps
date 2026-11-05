import XCTest
import CoreGraphics
import Metal
import QuartzCore
import PhotoIO

/// Issue #100: the detail view showed every photo mirrored top-to-bottom while
/// thumbnails were upright. Core Image writes rows bottom-up into an ordinary
/// texture but top-down into a CAMetalLayer drawable, and the older fixtures
/// only ever rendered into an ordinary texture. Both targets must come out
/// with the image's top row first.
@MainActor
final class HDRPresentationTests: XCTestCase {
    private enum Target: CaseIterable { case texture, layerDrawable }

    func testRowOrderSurvivesEveryTargetAndHeadroom() async throws {
        guard let renderer = HDRDisplayRenderer() else { throw XCTSkip("needs a Metal device") }
        // 4 x 8 fixture: top half extended red (2.0), bottom half blue (linear
        // P3, opaque), drawn at twice its size so the scale path runs too.
        let sourceWidth = 4, sourceHeight = 8
        var values: [Float] = []
        for y in 0..<sourceHeight {
            for _ in 0..<sourceWidth { values += y < sourceHeight / 2 ? [2, 0, 0, 1] : [0, 0, 1, 1] }
        }
        let image = try makeImage(values, width: sourceWidth, height: sourceHeight, space: renderer.colorSpace)
        let width = sourceWidth * 2, height = sourceHeight * 2
        for target in Target.allCases {
            for headroom: Float? in [nil, 1, 2, 16] {
                let pixels = try await render(renderer, image, into: target,
                                              width: width, height: height, headroom: headroom)
                let top = Array(pixels[0..<4])
                let bottomStart = (height - 1) * width * 4
                let bottom = Array(pixels[bottomStart..<bottomStart + 4])
                let label = "\(target), " + (headroom.map { "headroom \($0)" } ?? "no tone map")
                XCTAssertGreaterThan(top[0], top[2], "\(label): top row is not red: \(top) bottom: \(bottom)")
                XCTAssertGreaterThan(bottom[2], bottom[0], "\(label): bottom row is not blue: \(bottom) top: \(top)")
                if headroom == nil {
                    XCTAssertEqual(top[0], 2, accuracy: 0.02, "\(target): extended value was clamped")
                }
            }
        }
    }

    private func makeImage(_ values: [Float], width: Int, height: Int, space: CGColorSpace) throws -> CGImage {
        let data = values.withUnsafeBytes { Data($0) }
        let info = CGBitmapInfo.floatComponents.union(.byteOrder32Little)
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                                     bytesPerRow: width * 16, space: space, bitmapInfo: info, provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Renders like the app does, then blits the target into a shared buffer.
    /// The drawable comes from a CAMetalLayer configured as `HDRImageView`
    /// configures it; it needs no window and is never presented.
    private func render(_ renderer: HDRDisplayRenderer, _ image: CGImage, into target: Target,
                        width: Int, height: Int, headroom: Float?) async throws -> [Float] {
        let texture: any MTLTexture
        var drawable: (any CAMetalDrawable)?
        switch target {
        case .texture:
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        case .layerDrawable:
            let layer = CAMetalLayer()
            layer.device = renderer.device
            layer.pixelFormat = .rgba16Float
            layer.colorspace = renderer.colorSpace
            layer.wantsExtendedDynamicRangeContent = true
            layer.framebufferOnly = false
            layer.drawableSize = CGSize(width: width, height: height)
            drawable = try XCTUnwrap(layer.nextDrawable(), "CAMetalLayer vended no drawable")
            texture = drawable!.texture
        }
        let commands = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.render(image, to: texture, commandBuffer: commands, displayHeadroom: headroom)
        let bytesPerRow = width * 8
        let readback = try XCTUnwrap(renderer.device.makeBuffer(length: bytesPerRow * height,
                                                                options: .storageModeShared))
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        let status = await withCheckedContinuation { continuation in
            commands.addCompletedHandler { continuation.resume(returning: $0.status) }
            commands.commit()
        }
        XCTAssertEqual(status, .completed)
        withExtendedLifetime(drawable) {}  // hold the drawable until the GPU finished
        let raw = readback.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<width * height * 4).map { Float(Float16(bitPattern: raw[$0])) }
    }
}
