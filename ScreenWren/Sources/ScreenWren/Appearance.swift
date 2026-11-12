import AppKit

/// The suite's one corner-radius scale, always drawn with continuous corners.
enum CornerRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
}

/// A layer-backed view whose fill and border are semantic colours. A `cgColor` read once
/// keeps the appearance it was read in, so these are resolved again in `updateLayer`,
/// which AppKit calls with the view's current appearance after every change.
final class SemanticLayerView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    init(fill: NSColor? = nil, border: NSColor? = nil, borderWidth: CGFloat = 0, cornerRadius: CGFloat = 0) {
        fillColor = fill
        borderColor = border
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fillColor?.cgColor
        layer.borderColor = borderColor?.cgColor
        layer.borderWidth = borderWidth
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
    }
}

/// The captured image in an editor. Its hairline border follows light and dark mode.
final class CaptureImageView: NSImageView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    func applyBorder() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.borderWidth = 1
    }
}

/// A material background for floating panels: rounded, continuous, and clipped.
@MainActor
func makePanelBackground(material: NSVisualEffectView.Material = .popover) -> NSVisualEffectView {
    let background = NSVisualEffectView()
    background.material = material
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = CornerRadius.panel
    background.layer?.cornerCurve = .continuous
    background.layer?.masksToBounds = true
    return background
}

/// Fades floating panels in and out, with a short slide unless Reduce Motion is on.
@MainActor
enum PanelTransition {
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func present(_ window: NSWindow, slide: CGFloat = 8, alpha: CGFloat = 1) {
        let target = window.frame
        let slides = slide != 0 && !reducesMotion
        window.alphaValue = 0
        if slides { window.setFrameOrigin(CGPoint(x: target.minX, y: target.minY - slide)) }
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
            if slides { window.animator().setFrame(target, display: true) }
        }
    }

    /// The window stops taking clicks at once; `completion` runs after it has faded.
    static func dismiss(_ window: NSWindow, completion: @escaping @MainActor () -> Void) {
        guard window.isVisible else {
            completion()
            return
        }
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reducesMotion ? 0.12 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }
}
