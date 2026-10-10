#!/usr/bin/env swift
// Rebuild with: swift MacTools/Resources/generate-icon.swift [output.icns] [preview.png]
// Uses the system SF Symbol already used by Mac Tools. Colors and appearance are
// fixed so changing the Mac's light/dark setting does not change the generated art.
import AppKit
import Foundation

enum IconError: Error {
    case unavailableSymbol, bitmapCreation, pngEncoding, iconutilFailed(Int32)
}

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.bitmapCreation }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.24, alpha: 0.24)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.25, green: 0.30, blue: 0.82, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.27, blue: 0.78, alpha: 1),
               ending: NSColor(srgbRed: 0.43, green: 0.44, blue: 0.98, alpha: 1))!
        .draw(in: tile, angle: 70)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: .clear, ending: NSColor.white.withAlphaComponent(0.10))!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.20).setStroke()
    let rim = NSBezierPath(roundedRect: NSRect(x: 102, y: 102, width: 820, height: 820), xRadius: 183, yRadius: 183)
    rim.lineWidth = 2
    rim.stroke()

    let configuration = NSImage.SymbolConfiguration(pointSize: 500, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let mark = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { throw IconError.unavailableSymbol }
    let width: CGFloat = 548
    let height = width * mark.size.height / mark.size.width
    let markRect = NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 12, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow()
    markShadow.shadowColor = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.40, alpha: 0.18)
    markShadow.shadowBlurRadius = 10
    markShadow.shadowOffset = NSSize(width: 0, height: -6)
    markShadow.set()
    mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw IconError.pngEncoding }
    return png
}

func generateIcon() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let destination = arguments.first.map { URL(fileURLWithPath: $0) } ?? resources.appendingPathComponent("MacTools.icns")
    let preview = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsIcon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let iconset = work.appendingPathComponent("MacTools.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
    let sizes = [16, 32, 128, 256, 512]
    var rendered: [Int: Data] = [:]
    for size in sizes {
        for scale in [1, 2] {
            let pixels = size * scale
            let png: Data
            if let cached = rendered[pixels] { png = cached }
            else { png = try renderIcon(pixels: pixels); rendered[pixels] = png }
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png.write(to: iconset.appendingPathComponent(name))
        }
    }
    let compiled = work.appendingPathComponent("MacTools.icns")
    if let preview {
        try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rendered[1024]!.write(to: preview, options: .atomic)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", "--output", compiled.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw IconError.iconutilFailed(process.terminationStatus) }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: compiled).write(to: destination, options: .atomic)
    print("Generated \(destination.path)")
    if let preview { print("Preview: \(preview.path)") }
}

do { try generateIcon() }
catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
