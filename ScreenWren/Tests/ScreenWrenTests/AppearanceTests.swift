import AppKit
import XCTest

@testable import ScreenWren

final class AppearanceTests: XCTestCase {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> CGColor {
        var result: CGColor?
        try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance { result = color.cgColor }
        return try XCTUnwrap(result)
    }

    /// A `cgColor` read once keeps the appearance it was read in. These views must re-resolve
    /// their colours when the appearance changes, or a dark-mode switch leaves light-mode chrome.
    @MainActor func testCardAndCaptureBorderColoursFollowAppearanceChanges() throws {
        _ = NSApplication.shared
        let card = SemanticLayerView(fill: .windowBackgroundColor, border: .separatorColor, borderWidth: 1,
                                     cornerRadius: CornerRadius.card)
        let image = CaptureImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        card.frame = host.bounds
        host.addSubview(card)
        host.addSubview(image)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: name)
            host.layoutSubtreeIfNeeded()
            card.displayIfNeeded()
            let layer = try XCTUnwrap(card.layer)
            XCTAssertEqual(layer.backgroundColor, try resolved(.windowBackgroundColor, in: name), "\(name.rawValue)")
            XCTAssertEqual(layer.borderColor, try resolved(.separatorColor, in: name), "\(name.rawValue)")
            XCTAssertEqual(layer.cornerCurve, .continuous)
            XCTAssertEqual(image.layer?.borderColor, try resolved(.separatorColor, in: name), "\(name.rawValue)")
        }
        XCTAssertNotEqual(try resolved(.windowBackgroundColor, in: .aqua),
                          try resolved(.windowBackgroundColor, in: .darkAqua),
                          "The check is meaningless if the two appearances agree")
    }

    @MainActor func testFloatingPanelsUseTheRoundedMaterialAndFadeAway() async throws {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 40, height: 30) { _ in }
        let quick = QuickCaptureWindow(image: image, onAction: { _ in })
        let background = try XCTUnwrap(quick.window?.contentView as? NSVisualEffectView)
        XCTAssertEqual(background.layer?.cornerRadius, CornerRadius.panel)
        XCTAssertEqual(background.layer?.cornerCurve, .continuous)
        XCTAssertEqual(quick.window?.backgroundColor, .clear)

        quick.present()
        let window = try XCTUnwrap(quick.window)
        XCTAssertTrue(window.isVisible)
        var closed = false
        quick.onClose = { closed = true }
        quick.close()
        XCTAssertTrue(closed, "Callers see the thumbnail as gone at once")
        XCTAssertTrue(window.ignoresMouseEvents, "A fading panel takes no clicks")
        for _ in 0..<40 where window.isVisible { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(window.isVisible, "The panel is ordered out once its fade finishes")
    }
}
