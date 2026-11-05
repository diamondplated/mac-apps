import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
    // A flipped presenter (any SwiftUI-hosted CAMetalLayer) gets bottom-up
    // rows so the compositor's flip shows the photo upright.
    guard let flippedCommands = renderer.commandQueue.makeCommandBuffer() else {
        throw VerifyError(message: "could not allocate flipped render command")
    }
    renderer.render(image, to: texture, commandBuffer: flippedCommands, presentationFlipped: true)
    let flippedStatus = await withCheckedContinuation { continuation in
        flippedCommands.addCompletedHandler { completed in continuation.resume(returning: completed.status) }
        flippedCommands.commit()
    }
    try require(flippedStatus == .completed, "flipped offscreen Metal command failed")
    pixels.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: 16,
                         from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
    }
    for (index, actualBits) in pixels.enumerated() {
        let sourceRow = 1 - index / 8
        let expected = values[sourceRow * 8 + index % 8]
        let actual = Float(Float16(bitPattern: actualBits))
        try require(abs(actual - expected) < 0.02,
                    "flipped presentation component \(index) not bottom-up: \(actual), expected \(expected)")
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

func generatedGainMapSurvivesPreview() async throws {
    guard #available(macOS 26.0, *) else {
        print("SKIP: generated gain-map proof requires macOS 26 HDR statistics")
        return
    }
    try await checkGeneratedGainMapOnMainActor()
}

@MainActor
private func checkGeneratedGainMapOnMainActor() async throws {
    guard #available(macOS 26.0, *) else { return }
    guard let renderer = HDRDisplayRenderer() else {
        throw VerifyError(message: "generated gain-map proof needs Metal")
    }
    let width = 64, height = 32
    var sourcePixels = [Float]()
    for _ in 0..<height {
        for x in 0..<width {
            let value: Float = x < width / 2 ? 0.25 : 4
            sourcePixels += [value, value, value, 1]
        }
    }
    let data = sourcePixels.withUnsafeBytes { Data($0) }
    let provider = CGDataProvider(data: data as CFData)!
    let bitmap = CGBitmapInfo.floatComponents.union(.byteOrder32Little)
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    let raw = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: width * 16, space: renderer.colorSpace, bitmapInfo: bitmap,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let image = raw.copyWithCalculatedHDRStats() ?? raw
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-gainmap-\(UUID().uuidString).heic")
    defer { try? FileManager.default.removeItem(at: url) }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
        throw VerifyError(message: "HEIC encoder unavailable")
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
        kCGImageDestinationEncodeRequestOptions: [kCGImageDestinationEncodeBaseIsSDR: true],
        kCGImageDestinationLossyCompressionQuality: 1,
        kCGImagePropertyOrientation: 6,
    ] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "generated gain-map HEIC encoding failed")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw VerifyError(message: "generated HEIC source could not reopen")
    }
    try require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil,
                "generated HEIC lacks an ISO gain map")
    guard let preview = ImageReader.previewCGImage(url: url) else {
        throw VerifyError(message: "production HDR preview decode failed")
    }
    try require(preview.width == height && preview.height == width, "HDR preview lost EXIF orientation")
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
        width: preview.width, height: preview.height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = renderer.device.makeTexture(descriptor: descriptor)!
    let commands = renderer.commandQueue.makeCommandBuffer()!
    renderer.render(preview, to: texture, commandBuffer: commands)
    let status = await withCheckedContinuation { continuation in
        commands.addCompletedHandler { continuation.resume(returning: $0.status) }
        commands.commit()
    }
    try require(status == .completed, "gain-map render failed")
    var output = [UInt16](repeating: 0, count: preview.width * preview.height * 4)
    output.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: preview.width * 8,
                         from: MTLRegionMake2D(0, 0, preview.width, preview.height), mipmapLevel: 0)
    }
    // Orientation 6 rotates the left dark / right bright halves into top dark
    // and bottom bright. Sample away from the lossy codec's shared edge.
    let top = Float(Float16(bitPattern: output[(8 * preview.width + 16) * 4]))
    let bottom = Float(Float16(bitPattern: output[(48 * preview.width + 16) * 4]))
    try require(top > 0.1 && top < 0.5 && bottom > 2,
                "gain-map highlight or orientation lost: top=\(top), bottom=\(bottom)")
}
