import AppKit

/// A colour's hex value in sRGB, the space the web and most design tools mean by hex.
/// Colours outside sRGB (a vivid Display P3 red, say) are converted and clamped.
func hexString(for colour: NSColor) -> String? {
    guard let srgb = colour.usingColorSpace(.extendedSRGB) ?? colour.usingColorSpace(.sRGB) else { return nil }
    func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
}

/// The sRGB colour of a "#RRGGBB" value.
func colour(fromHex hex: String) -> NSColor? {
    guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

/// Pick Colour: the system's sampler loupe, then the hex value on the clipboard. The last
/// five picks are kept for this session only.
@MainActor
final class ColourPicker {
    static let recentLimit = 5
    private(set) var recent: [String] = []
    var onCopied: ((String) -> Void)?
    var onCancelled: (() -> Void)?
    var onFailed: (() -> Void)?
    private let pasteboard: NSPasteboard
    private let sample: @MainActor (@escaping @MainActor (NSColor?) -> Void) -> Void
    private(set) var isSampling = false

    init(pasteboard: NSPasteboard = .general,
         sample: @escaping @MainActor (@escaping @MainActor (NSColor?) -> Void) -> Void = ColourPicker.systemSampler) {
        self.pasteboard = pasteboard
        self.sample = sample
    }

    /// Kept alive while its loupe is up.
    private static var activeSampler: NSColorSampler?

    static func systemSampler(_ completion: @escaping @MainActor (NSColor?) -> Void) {
        let sampler = NSColorSampler()
        activeSampler = sampler
        sampler.show { colour in
            MainActor.assumeIsolated {
                ColourPicker.activeSampler = nil
                completion(colour)
            }
        }
    }

    func pick() {
        guard !isSampling else { return }
        isSampling = true
        sample { [weak self] colour in
            guard let self else { return }
            self.isSampling = false
            // Esc in the loupe returns no colour, and nothing is copied.
            guard let colour, let hex = hexString(for: colour) else {
                self.onCancelled?()
                return
            }
            self.copy(hex)
        }
    }

    /// Copies a hex value and moves it to the front of the recent picks.
    func copy(_ hex: String) {
        _ = ClipboardDeliveryOrder.shared.begin()
        pasteboard.clearContents()
        guard pasteboard.setString(hex, forType: .string) else {
            onFailed?()
            return
        }
        recent.removeAll { $0 == hex }
        recent.insert(hex, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        onCopied?(hex)
    }
}

/// A small rounded swatch for menus and the status notice.
@MainActor
func colourSwatchImage(_ colour: NSColor, side: CGFloat = 14) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        colour.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        return true
    }
}
