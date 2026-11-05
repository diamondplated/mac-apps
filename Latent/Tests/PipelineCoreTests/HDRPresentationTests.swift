import XCTest
import CoreGraphics
import Metal
import PhotoIO

/// Issue #100: the detail view showed photos upside down while thumbnails
/// were upright. The app always renders with the screen's headroom, which
/// the older fixtures never combined with an asymmetric image.
@MainActor
final class HDRPresentationTests: XCTestCase {
    func testRowOrderSurvivesEveryHeadroom() async throws {
        guard let renderer = HDRDisplayRenderer() else { throw XCTSkip("needs a Metal device") }
        // 2 x 4 fixture: top half red, bottom half blue (linear P3, opaque).
        let width = 2, height = 4
        var values: [Float] = []
        for y in 0..<height {
            for _ in 0..<width { values += y < height / 2 ? [1, 0, 0, 1] : [0, 0, 1, 1] }
        }
        let image = try makeImage(values, width: width, height: height, space: renderer.colorSpace)
        for headroom: Float? in [nil, 1, 2, 16] {
            let pixels = try await render(renderer, image, width: width, height: height, headroom: headroom)
            let top = Array(pixels[0..<4]), bottom = Array(pixels[(height - 1) * width * 4..<(height - 1) * width * 4 + 4])
            let label = headroom.map { "headroom \($0)" } ?? "no tone map"
            XCTAssertGreaterThan(top[0], top[2], "\(label): top row is not red: \(top) bottom: \(bottom)")
            XCTAssertGreaterThan(bottom[2], bottom[0], "\(label): bottom row is not blue: \(bottom) top: \(top)")
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

    private func render(_ renderer: HDRDisplayRenderer, _ image: CGImage,
                        width: Int, height: Int, headroom: Float?) async throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        renderer.render(image, to: texture, commandBuffer: commands, displayHeadroom: headroom)
        let status = await withCheckedContinuation { continuation in
            commands.addCompletedHandler { continuation.resume(returning: $0.status) }
            commands.commit()
        }
        XCTAssertEqual(status, .completed)
        var raw = [UInt16](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }
}
