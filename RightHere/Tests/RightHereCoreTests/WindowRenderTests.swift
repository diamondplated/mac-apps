import AppKit
import SwiftUI
import XCTest
@testable import RightHereCore

/// Renders the app's window offscreen. With RIGHTHERE_WINDOW_SNAPSHOT=/dir/name.png it also
/// writes name-{light,dark}-{on,off}.png beside it.
final class WindowRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testWindowRendersInBothAppearancesAndStates() throws {
        let path = ProcessInfo.processInfo.environment["RIGHTHERE_WINDOW_SNAPSHOT"]
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for enabled in [true, false] {
                let hosting = NSHostingView(rootView: StatusView(isEnabled: enabled))
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(origin: .zero, size: StatusView.size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = hosting.appearance
                window.contentView = hosting
                defer { window.contentView = nil }
                hosting.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(hosting.fittingSize.height, StatusView.size.height + 1, "content must fit the window (\(mode) \(enabled))")
                guard let path else { continue }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let base = URL(fileURLWithPath: path).deletingPathExtension().path
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(base)-\(mode)-\(enabled ? "on" : "off").png"))
            }
        }
    }
}
