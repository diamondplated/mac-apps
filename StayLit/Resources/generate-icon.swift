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
        NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1), ending: NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.12, alpha: 1))!.draw(in: background, angle: -70)
        NSColor.white.setFill()
        // Saucer.
        NSBezierPath(roundedRect: NSRect(x: 232, y: 236, width: 560, height: 64), xRadius: 32, yRadius: 32).fill()
        // Cup: a flat rim curving down to a narrower base.
        let cup = NSBezierPath()
        cup.move(to: NSPoint(x: 282, y: 640))
        cup.line(to: NSPoint(x: 702, y: 640))
        cup.curve(to: NSPoint(x: 572, y: 318), controlPoint1: NSPoint(x: 702, y: 470), controlPoint2: NSPoint(x: 662, y: 330))
        cup.line(to: NSPoint(x: 412, y: 318))
        cup.curve(to: NSPoint(x: 282, y: 640), controlPoint1: NSPoint(x: 322, y: 330), controlPoint2: NSPoint(x: 282, y: 470))
        cup.close()
        cup.fill()
        // Handle.
        let handle = NSBezierPath(ovalIn: NSRect(x: 628, y: 432, width: 168, height: 168))
        handle.lineWidth = 44
        NSColor.white.setStroke()
        handle.stroke()
        // Steam.
        for x in [402.0, 492.0, 582.0] {
            let steam = NSBezierPath()
            steam.lineWidth = 30; steam.lineCapStyle = .round
            steam.move(to: NSPoint(x: x, y: 700))
            steam.curve(to: NSPoint(x: x, y: 840), controlPoint1: NSPoint(x: x + 44, y: 746), controlPoint2: NSPoint(x: x - 44, y: 794))
            NSColor.white.withAlphaComponent(0.85).setStroke()
            steam.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
