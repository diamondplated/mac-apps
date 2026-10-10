import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.7, blue: 0.64, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.33, blue: 0.47, alpha: 1))!.draw(in: background, angle: -70)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 345, y: 222, width: 334, height: 580), xRadius: 164, yRadius: 164).fill()
        NSColor(calibratedRed: 0.05, green: 0.5, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 489, y: 595, width: 46, height: 118), xRadius: 23, yRadius: 23).fill()
        for (x, sign) in [(240.0, 1.0), (784.0, -1.0)] {
            let path = NSBezierPath(); path.lineWidth = 34; path.lineCapStyle = .round; path.lineJoinStyle = .round
            let y = sign > 0 ? 620.0 : 410.0
            path.move(to: NSPoint(x: x, y: 410)); path.line(to: NSPoint(x: x, y: 620))
            path.move(to: NSPoint(x: x-48, y: y-sign*48)); path.line(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x+48, y: y-sign*48))
            NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
