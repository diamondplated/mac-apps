import Foundation
import CoreGraphics
import Metal
import PhotoIO
import PipelineCore

func hdrDisplayPreservesExtendedPixels() async throws {
    try await checkHDRDisplayOnMainActor()
}

@MainActor
private func checkHDRDisplayOnMainActor() async throws {
    try require(ImageMemoryPolicy.previewMaxDimension(width: 16, height: 8, maxBytes: 16 * 8 * 28) == 16,
                "safe preview lost full resolution")
    try require(ImageMemoryPolicy.previewMaxDimension(width: 20_000, height: 20_000, maxBytes: 28 * 100 * 100) == 78,
                "oversized preview was not bounded before decode")
    try require(ImageMemoryPolicy.previewMaxDimension(width: Int.max, height: 1, maxBytes: 28 * 100) ?? Int.max <= 100,
                "extreme aspect ratio preview exceeded pixel budget")
    try require(ImageMemoryPolicy.previewMaxDimension(width: 0, height: 1) == nil,
                "invalid preview dimensions accepted")
    guard let renderer = HDRDisplayRenderer() else {
        print("SKIP: offscreen HDR display needs a Metal device")
        return
    }
    // Synthetic extended-linear P3, with highlights above SDR white. No user
    // image, display, NSView, window, or installed color profile is involved.
    let values: [Float] = [2, 1.25, 0.5, 1, 0.25, 0.5, 0.75, 1,
                               0.125, 2.5, 0.25, 1, 0.75, 0.25, 3, 1]
    let data = values.withUnsafeBytes { Data($0) }
    let info = CGBitmapInfo.floatComponents.union(.byteOrder32Little)
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: 2, height: 2, bitsPerComponent: 32, bitsPerPixel: 128,
              bytesPerRow: 32, space: renderer.colorSpace, bitmapInfo: info,
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw VerifyError(message: "could not create synthetic HDR fixture")
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = renderer.device.makeTexture(descriptor: descriptor),
          let commands = renderer.commandQueue.makeCommandBuffer() else {
        throw VerifyError(message: "could not allocate offscreen HDR render target")
    }
    renderer.render(image, to: texture, commandBuffer: commands)
    let status = await withCheckedContinuation { continuation in
        commands.addCompletedHandler { completed in continuation.resume(returning: completed.status) }
        commands.commit()
    }
    try require(status == .completed, "offscreen Metal command failed")
    var pixels = [UInt16](repeating: 0, count: 16)
    pixels.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: 16,
                         from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
    }
    for (index, expected) in values.enumerated() {
        let actual = Float(Float16(bitPattern: pixels[index]))
        try require(abs(actual - expected) < 0.02,
                    "HDR/P3 component \(index) was clipped or changed: \(actual), expected \(expected)")
    }
    // Exercise the same tone mapping path used with the current NSScreen
    // headroom; this needs no screen or window. On macOS 14 the EDR surface
    // retains native values and the compositor supplies the display clamp.
    if #available(macOS 26.0, *) {
        guard let mapped = renderer.commandQueue.makeCommandBuffer() else {
            throw VerifyError(message: "could not allocate tone-map command")
        }
        let neutralValues = [Float](repeating: 4, count: 16).enumerated().map { $0.offset % 4 == 3 ? Float(1) : $0.element }
        let neutralData = neutralValues.withUnsafeBytes { Data($0) }
        let neutralProvider = CGDataProvider(data: neutralData as CFData)!
        let neutral = CGImage(width: 2, height: 2, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 32, space: renderer.colorSpace, bitmapInfo: info, provider: neutralProvider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        renderer.render(neutral, to: texture, commandBuffer: mapped, displayHeadroom: 1)
        let mappedStatus = await withCheckedContinuation { continuation in
            mapped.addCompletedHandler { completed in continuation.resume(returning: completed.status) }
            mapped.commit()
        }
        try require(mappedStatus == .completed, "tone-map command failed")
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 16,
                             from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        for index in pixels.indices where index % 4 != 3 {
            let value = Float(Float16(bitPattern: pixels[index]))
            try require(value.isFinite && value >= 0 && value <= 1.01,
                        "display tone mapping exceeded SDR headroom: \(value)")
        }
    }
}
