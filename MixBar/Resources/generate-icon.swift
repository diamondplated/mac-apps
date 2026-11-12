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
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.80, alpha: 1), ending: NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.82, alpha: 1))!.draw(in: background, angle: -70)
        // Three faders: a track each and a knob at a different level.
        for (x, level) in [(312.0, 0.62), (512.0, 0.34), (712.0, 0.80)] {
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 18, y: 232, width: 36, height: 560), xRadius: 18, yRadius: 18).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 18, y: 232, width: 36, height: 560 * level), xRadius: 18, yRadius: 18).fill()
            let knob = NSBezierPath(roundedRect: NSRect(x: x - 72, y: 232 + 560 * level - 44, width: 144, height: 88), xRadius: 44, yRadius: 44)
            NSColor.white.setFill()
            knob.fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
