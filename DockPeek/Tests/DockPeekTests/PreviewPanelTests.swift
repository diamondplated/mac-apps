import Cocoa
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
}
