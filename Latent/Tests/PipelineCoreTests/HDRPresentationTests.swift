import XCTest
import AppKit
import SwiftUI
import QuartzCore
import CoreGraphics
import Metal
import PhotoIO

/// Regression for the detail view showing every photo upside down while the
/// thumbnails were right: the Metal surface wrote top-down rows into a layer
/// that Core Animation flips on screen.
@MainActor
final class HDRPresentationTests: XCTestCase {
    /// The production view sits inside SwiftUI exactly like this. If AppKit
    /// stops flipping the layer, the renderer must stop compensating too, so
    /// this pins the half of the bug no pixel readback can see.
    func testSwiftUIHostedMetalLayerContentsAreFlipped() throws {
        _ = NSApplication.shared
        let probe = LayerProbe()
        let host = NSHostingView(rootView: ProbeRepresentable(probe: probe).frame(width: 40, height: 20))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        // Never ordered front: nothing appears on the runner's desktop.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let view = try XCTUnwrap(probe.view, "representable was never created")
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer, "view lost its CAMetalLayer")
        print("HDRPresentation chain: \(describeChain(view))")
        XCTAssertTrue(layer.contentsAreFlipped(),
                      "SwiftUI-hosted CAMetalLayer is not flipped; hierarchy: \(describeChain(view))")
        _ = window
    }

    /// With a flipped presenter the renderer writes Core Image's bottom-up
    /// rows, so the compositor's flip puts the image's top row on top.
    func testFlippedPresentationWritesBottomUpRows() async throws {
        guard let renderer = HDRDisplayRenderer() else { throw XCTSkip("needs a Metal device") }
        // 1 x 2 fixture: top row red, bottom row blue (linear P3, opaque).
        let values: [Float] = [1, 0, 0, 1,
                               0, 0, 1, 1]
        let image = try makeImage(values, width: 1, height: 2, space: renderer.colorSpace)
        let upright = try await render(renderer, image, width: 1, height: 2, flipped: false)
        let flipped = try await render(renderer, image, width: 1, height: 2, flipped: true)
        // Unflipped presenter: texture memory matches CGImage row order.
        XCTAssertEqual(upright[0], 1, accuracy: 0.02); XCTAssertEqual(upright[6], 1, accuracy: 0.02)
        // Flipped presenter: rows reversed in memory, upright on screen.
        XCTAssertEqual(flipped[2], 1, accuracy: 0.02, "top texture row should hold the image's bottom (blue) row")
        XCTAssertEqual(flipped[4], 1, accuracy: 0.02, "bottom texture row should hold the image's top (red) row")
        XCTAssertEqual(flipped[0], 0, accuracy: 0.02)
    }

    private func makeImage(_ values: [Float], width: Int, height: Int, space: CGColorSpace) throws -> CGImage {
        let data = values.withUnsafeBytes { Data($0) }
        let info = CGBitmapInfo.floatComponents.union(.byteOrder32Little)
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                                  bytesPerRow: width * 16, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw XCTSkip("could not build fixture")
        }
        return image
    }

    private func render(_ renderer: HDRDisplayRenderer, _ image: CGImage,
                        width: Int, height: Int, flipped: Bool) async throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        renderer.render(image, to: texture, commandBuffer: commands, presentationFlipped: flipped)
        let status = await withCheckedContinuation { continuation in
            commands.addCompletedHandler { continuation.resume(returning: $0.status) }
            commands.commit()
        }
        XCTAssertEqual(status, .completed)
        var raw = [UInt16](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }
}

/// View and layer flip state from the probe up to the window, for diagnosis.
@MainActor
private func describeChain(_ start: NSView) -> String {
    var parts: [String] = []
    var view: NSView? = start
    while let v = view {
        parts.append("\(type(of: v)) viewFlipped=\(v.isFlipped) layer=\(v.layer.map { "\(type(of: $0)) geoFlipped=\($0.isGeometryFlipped) contentsFlipped=\($0.contentsAreFlipped())" } ?? "nil")")
        view = v.superview
    }
    var layer: CALayer? = start.layer?.superlayer
    while let l = layer {
        parts.append("superlayer \(type(of: l)) geoFlipped=\(l.isGeometryFlipped)")
        layer = l.superlayer
    }
    return parts.joined(separator: " | ")
}

@MainActor
private final class LayerProbe { var view: NSView? }

/// Same layer setup as HDRImageView's MetalImageNSView.
private struct ProbeRepresentable: NSViewRepresentable {
    let probe: LayerProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = CAMetalLayer()
        probe.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
