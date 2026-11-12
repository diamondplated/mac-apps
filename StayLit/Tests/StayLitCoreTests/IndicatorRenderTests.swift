import AppKit
import SwiftUI
import XCTest
@testable import StayLitCore

/// Renders the on-screen indicator offscreen. With STAYLIT_INDICATOR_SNAPSHOT=/dir/name.png
/// it also writes name-{light,dark}-{brightness,volume,muted}.png beside it.
final class IndicatorRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testIndicatorRendersInBothAppearances() throws {
        let path = ProcessInfo.processInfo.environment["STAYLIT_INDICATOR_SNAPSHOT"]
        let models: [(String, IndicatorModel)] = [
            ("brightness", IndicatorModel(kind: .brightness, level: 0.625, displayName: "DELL U2723QE")),
            ("volume", IndicatorModel(kind: .volume, level: 0.3125, displayName: "LG HDR 4K")),
            ("muted", IndicatorModel(kind: .muted, level: 0.5, displayName: "A Display With A Very Long Name That Must Not Wrap Onto A Second Or Third Line Of The Indicator"))
        ]
        for (name, model) in models {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let hosting = NSHostingView(rootView: IndicatorView(model: model))
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(origin: .zero, size: IndicatorView.size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.contentView = nil }
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.fittingSize.width, IndicatorView.size.width, accuracy: 1, "\(name) \(mode)")
                XCTAssertEqual(hosting.fittingSize.height, IndicatorView.size.height, accuracy: 1, "\(name) \(mode): a long name must not wrap")
                guard let path else { continue }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let base = URL(fileURLWithPath: path).deletingPathExtension().path
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(base)-\(mode)-\(name).png"))
            }
        }
    }

    func testSymbolFollowsLevel() {
        XCTAssertEqual(IndicatorModel(kind: .volume, level: 0, displayName: "").symbol, "speaker.fill")
        XCTAssertEqual(IndicatorModel(kind: .volume, level: 0.2, displayName: "").symbol, "speaker.wave.1.fill")
        XCTAssertEqual(IndicatorModel(kind: .volume, level: 0.9, displayName: "").symbol, "speaker.wave.3.fill")
        XCTAssertEqual(IndicatorModel(kind: .muted, level: 0.9, displayName: "").symbol, "speaker.slash.fill")
        XCTAssertEqual(IndicatorModel(kind: .brightness, level: 2, displayName: "").level, 1)
    }
}
