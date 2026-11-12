import Cocoa
import SwiftUI
import XCTest
@testable import DockPeek

final class PreviewPanelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testHideOrdersOutAnAlreadyTransparentPanel() {
        let panel = PreviewPanel()
        defer { panel.orderOut(nil) }
        panel.orderFront(nil)
        panel.alphaValue = 0
        XCTAssertTrue(panel.isVisible)

        panel.hide()

        let hidden = expectation(description: "Transparent preview is ordered out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertFalse(panel.isVisible)
            hidden.fulfill()
        }
        wait(for: [hidden], timeout: 2)
    }

    func testNewPreviewSurvivesPreviousHideCompletion() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = PreviewPanel()
        defer { panel.orderOut(nil) }
        let item = HoveredDockItem(
            pid: 1, title: "Preview test", icon: nil,
            frame: CGRect(x: screen.frame.midX, y: screen.visibleFrame.minY, width: 64, height: 64),
            orientation: .bottom
        )
        let window = WindowInfo(
            id: 1, pid: 1, title: "Preview test", bounds: .zero,
            thumbnail: nil, appIcon: nil, axElement: nil, isMinimized: false
        )
        panel.show(dockItem: item, windows: [window], onSelect: { _ in }, onClose: { _ in })
        panel.alphaValue = 1
        panel.hide()
        panel.show(dockItem: item, windows: [window], onSelect: { _ in }, onClose: { _ in })

        let visible = expectation(description: "New preview stays visible after old fade-out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
            visible.fulfill()
        }
        wait(for: [visible], timeout: 2)
    }

    func testTabListsFitSmallScreensAndRemainScrollable() {
        let tabs = (1...40).map { TabInfo(title: "Tab \($0)", isSelected: $0 == 1, axElement: nil) }
        let window = WindowInfo(
            id: 1, pid: 1, title: "Browser", bounds: .zero,
            thumbnail: nil, appIcon: nil, axElement: nil, tabs: tabs
        )
        let layout = PreviewLayout(windows: [window, window], availableSize: CGSize(width: 500, height: 350))
        XCTAssertEqual(layout.size.width, 500)
        XCTAssertEqual(layout.size.height, 350)
        XCTAssertGreaterThan(layout.tabListHeight, PreviewLayout.tabRowHeight)
        XCTAssertLessThan(layout.tabListHeight, CGFloat(tabs.count) * PreviewLayout.tabRowHeight)

        let large = PreviewLayout(windows: [window], availableSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(large.tabListHeight, 5 * PreviewLayout.tabRowHeight)
        XCTAssertEqual(large.size.width, 306)
    }

    func testWindowOnlyPreviewStaysCompact() {
        let window = WindowInfo(id: 1, pid: 1, title: "Editor", bounds: .zero, thumbnail: nil, appIcon: nil, axElement: nil)
        let layout = PreviewLayout(windows: [window], availableSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(layout.size.width, 246)
        XCTAssertEqual(layout.size.height, PreviewLayout.baseHeight)
        XCTAssertEqual(layout.tabListHeight, 0)
    }

    func testTabbedPreviewRenders() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = PreviewPanel()
        defer { panel.orderOut(nil) }
        let titles = ["Project overview", "Design notes", "A long tab title that should truncate cleanly and retain its full tooltip", "Project overview", "Pull requests", "Documentation", "Release notes", "Settings"]
        let tabs = titles.enumerated().map { TabInfo(title: $0.element, isSelected: $0.offset == 1, axElement: nil) }
        let window = WindowInfo(id: 1, pid: 1, title: "Design notes", bounds: .zero, thumbnail: nil, appIcon: nil, axElement: nil, tabs: tabs)
        let item = HoveredDockItem(pid: 1, title: "Browser", icon: nil, frame: CGRect(x: screen.frame.midX, y: screen.visibleFrame.minY, width: 64, height: 64), orientation: .bottom)
        panel.show(dockItem: item, windows: [window], onSelect: { _ in }, onClose: { _ in })
        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.height, PreviewLayout.baseHeight + PreviewLayout.tabHeaderHeight + 5 * PreviewLayout.tabRowHeight)
        if let path = ProcessInfo.processInfo.environment["DOCKPEEK_PREVIEW_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// With DOCKPEEK_PREVIEW_SNAPSHOT=/dir/name.png also writes name-{light,dark}-{tabs,windows}.png.
    func testRendersInBothAppearancesWithAndWithoutTabs() throws {
        let path = ProcessInfo.processInfo.environment["DOCKPEEK_PREVIEW_SNAPSHOT"]
        func thumbnail(_ color: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 320, height: 200))
            image.lockFocus()
            NSGradient(starting: color, ending: color.blended(withFraction: 0.5, of: .white) ?? color)?.draw(in: NSRect(x: 0, y: 0, width: 320, height: 200), angle: 90)
            image.unlockFocus()
            return image
        }
        let icon = NSWorkspace.shared.icon(for: .applicationBundle)
        let titles = ["Project overview", "Design notes", "A long tab title that should truncate cleanly", "Pull requests", "Documentation", "Release notes"]
        let tabs = titles.enumerated().map { TabInfo(title: $0.element, isSelected: $0.offset == 1, axElement: nil) }
        let windows = [
            WindowInfo(id: 1, pid: 1, title: "Design notes", bounds: .zero, thumbnail: thumbnail(.systemIndigo), appIcon: icon, axElement: nil),
            WindowInfo(id: 2, pid: 1, title: "Minimized window", bounds: .zero, thumbnail: nil, appIcon: icon, axElement: nil, isMinimized: true),
            WindowInfo(id: 3, pid: 1, title: "Inbox", bounds: .zero, thumbnail: thumbnail(.systemTeal), appIcon: icon, axElement: nil, isMinimized: true)
        ]
        let withTabs = windows.map { WindowInfo(id: $0.id, pid: 1, title: $0.title, bounds: .zero, thumbnail: $0.thumbnail, appIcon: icon, axElement: nil, isMinimized: $0.isMinimized, tabs: $0.id == 1 ? tabs : []) }
        for (name, set) in [("windows", windows), ("tabs", withTabs)] {
            let layout = PreviewLayout(windows: set, availableSize: CGSize(width: 1400, height: 900))
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let view = PreviewView(appName: "Browser", appIcon: icon, windows: set, tabListHeight: layout.tabListHeight, onSelectWindow: { _ in }, onCloseWindow: { _ in })
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(origin: .zero, size: layout.size)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(hosting.fittingSize.width, 0)
                guard let path else { continue }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let url = URL(fileURLWithPath: path).deletingPathExtension()
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: url.path + "-\(mode)-\(name).png"))
            }
        }
    }
}
