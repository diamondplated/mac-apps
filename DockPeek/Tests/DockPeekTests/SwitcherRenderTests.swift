import Cocoa
import SwiftUI
import XCTest
@testable import DockPeek

/// Renders the switcher panel offscreen. With DOCKPEEK_PREVIEW_SNAPSHOT=/dir/name.png it
/// also writes name-switcher-{light,dark}-{row,wrap,scroll}.png beside it.
final class SwitcherRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func thumbnail(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSGradient(starting: color, ending: color.blended(withFraction: 0.5, of: .white) ?? color)?
            .draw(in: NSRect(x: 0, y: 0, width: 320, height: 200), angle: 90)
        image.unlockFocus()
        return image
    }

    private func model(count: Int, highlight: Int) -> SwitcherModel {
        let icon = NSWorkspace.shared.icon(for: .applicationBundle)
        let titles = ["Design notes", "Inbox", "A long window title that should truncate cleanly", "Terminal", "Release checklist", "Calendar", "Pull requests", "Downloads", "Music", "Notes", "Preview", "Settings"]
        let colors: [NSColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemPurple]
        let model = SwitcherModel()
        model.entries = (0..<count).map { index in
            SwitcherEntry(
                candidate: SwitcherCandidate(id: CGWindowID(index + 1), pid: 1, title: titles[index % titles.count], isMinimized: index == count - 1, axIndex: index),
                appName: "App", appIcon: icon, axElement: nil
            )
        }
        // Every third window has no capture yet and shows its app icon.
        for index in 0..<count where index % 3 != 2 {
            model.thumbnails[CGWindowID(index + 1)] = thumbnail(colors[index % colors.count])
        }
        model.highlight = highlight
        return model
    }

    func testRendersOneRowWrappedAndScrollingInBothAppearances() throws {
        let path = ProcessInfo.processInfo.environment["DOCKPEEK_PREVIEW_SNAPSHOT"]
        let fixtures: [(String, Int, Int, CGSize)] = [
            ("row", 4, 1, CGSize(width: 1600, height: 900)),
            ("wrap", 11, 6, CGSize(width: 1300, height: 900)),
            ("scroll", 30, 27, CGSize(width: 1300, height: 560))
        ]
        for (name, count, highlight, available) in fixtures {
            let layout = SwitcherLayout(count: count, availableSize: available)
            XCTAssertEqual(layout.scrolls, name == "scroll", name)
            XCTAssertEqual(layout.rows > 1, name != "row", name)
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let view = SwitcherView(model: model(count: count, highlight: highlight), layout: layout, onSelect: { _ in })
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(origin: .zero, size: layout.size)
                // A window that is never ordered in, so scrolling has a real view tree to act on.
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.contentView = nil }
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.fittingSize.width, layout.size.width, accuracy: 1, "\(name) \(mode)")
                guard let path else { continue }
                // Let the scroll-to-highlight settle before capturing.
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let base = URL(fileURLWithPath: path).deletingPathExtension().path
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(base)-switcher-\(mode)-\(name).png"))
            }
        }
    }
}
