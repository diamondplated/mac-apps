import SwiftUI
import AppKit
import QuartzCore
import Metal
import PhotoIO

/// A static EDR surface, with the existing SwiftUI image path when Metal fails.
struct HDRImageView: View {
    let image: CGImage
    @State private var useFallback = false

    var body: some View {
        Group {
            if useFallback {
                Image(decorative: image, scale: 1.0, orientation: .up)
                    .resizable().interpolation(.high)
            } else {
                MetalImageSurface(image: image) { useFallback = true }
            }
        }
        .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
    }
}

private struct MetalImageSurface: NSViewRepresentable {
    let image: CGImage
    let failed: @MainActor () -> Void

    func makeNSView(context: Context) -> MetalImageNSView {
        MetalImageNSView(image: image, failed: failed)
    }

    func updateNSView(_ view: MetalImageNSView, context: Context) {
        view.update(image: image)
    }
}

@MainActor
private final class MetalImageNSView: NSView {
    private let renderer = HDRDisplayRenderer()
    private let metalLayer = CAMetalLayer()
    private var image: CGImage
    private let failed: @MainActor () -> Void
    private var didFail = false

    init(image: CGImage, failed: @escaping @MainActor () -> Void) {
        self.image = image
        self.failed = failed
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = renderer?.colorSpace
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.allowsNextDrawableTimeout = true
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(image: CGImage) {
        guard self.image !== image else { return }
        self.image = image
        render()
    }

    override func layout() { super.layout(); render() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); render() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); render() }
    @objc private func screenChanged() { render() }

    private func render() {
        // No continuous display link: static photos only draw on content,
        // layout, backing-scale or display changes.
        guard !didFail, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        guard let renderer else { fallback(); return }
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        metalLayer.drawableSize = size
        guard let drawable = metalLayer.nextDrawable(),
              let commands = renderer.commandQueue.makeCommandBuffer() else { fallback(); return }
        let headroom = Float(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        // SwiftUI hosts this view in a flipped parent, so AppKit geometry-flips
        // the layer and Core Animation would show the drawable upside down.
        renderer.render(image, to: drawable.texture, commandBuffer: commands, displayHeadroom: headroom,
                        presentationFlipped: metalLayer.contentsAreFlipped())
        commands.addCompletedHandler { [weak self] completed in
            guard completed.status == .error else { return }
            Task { @MainActor in self?.fallback() }
        }
        commands.present(drawable)
        commands.commit()
    }

    private func fallback() {
        guard !didFail else { return }
        didFail = true
        // Avoid mutating SwiftUI state during an update/layout callback.
        Task { @MainActor [failed] in failed() }
    }
}
