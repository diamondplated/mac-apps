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
        NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1), ending: NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.82, alpha: 1))!.draw(in: background, angle: -70)
        // A context menu: a white card with three rows, the first highlighted.
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 292, y: 232, width: 460, height: 560), xRadius: 64, yRadius: 64).fill()
        NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 328, y: 604, width: 388, height: 124), xRadius: 40, yRadius: 40).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 368, y: 654, width: 250, height: 24), xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 368, y: 500, width: 290, height: 24), xRadius: 12, yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 368, y: 392, width: 200, height: 24), xRadius: 12, yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 368, y: 284, width: 250, height: 24), xRadius: 12, yRadius: 12).fill()
        // The pointer that opened it.
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: 196, y: 842))
        pointer.line(to: NSPoint(x: 196, y: 622))
        pointer.line(to: NSPoint(x: 254, y: 676))
        pointer.line(to: NSPoint(x: 300, y: 584))
        pointer.line(to: NSPoint(x: 352, y: 608))
        pointer.line(to: NSPoint(x: 306, y: 700))
        pointer.line(to: NSPoint(x: 384, y: 706))
        pointer.close()
        NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.40, alpha: 1).setFill()
        pointer.fill()
        NSColor.white.setStroke()
        pointer.lineWidth = 14
        pointer.lineJoinStyle = .round
        pointer.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
