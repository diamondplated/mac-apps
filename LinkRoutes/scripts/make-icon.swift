import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let outline = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.21, blue: 0.68, alpha: 1), ending: NSColor(calibratedRed: 0.56, green: 0.42, blue: 0.95, alpha: 1))!
        gradient.draw(in: outline, angle: 55)
        // A single incoming route splits into two clean browser destinations.
        let route = NSBezierPath(); route.lineWidth = 72; route.lineCapStyle = .round; route.lineJoinStyle = .round
        route.move(to: NSPoint(x: 320, y: 270)); route.line(to: NSPoint(x: 320, y: 500)); route.curve(to: NSPoint(x: 500, y: 680), controlPoint1: NSPoint(x: 320, y: 640), controlPoint2: NSPoint(x: 380, y: 680)); route.line(to: NSPoint(x: 710, y: 680))
        NSColor.white.setStroke(); route.stroke()
        let branch = NSBezierPath(); branch.lineWidth = 72; branch.lineCapStyle = .round
        branch.move(to: NSPoint(x: 320, y: 430)); branch.line(to: NSPoint(x: 710, y: 430)); branch.stroke()
        for y in [430.0, 680.0] {
            let arrow = NSBezierPath(); arrow.lineWidth = 64; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 638, y: y - 85)); arrow.line(to: NSPoint(x: 728, y: y)); arrow.line(to: NSPoint(x: 638, y: y + 85)); arrow.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
