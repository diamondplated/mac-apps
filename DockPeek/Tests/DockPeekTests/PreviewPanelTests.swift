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
}
