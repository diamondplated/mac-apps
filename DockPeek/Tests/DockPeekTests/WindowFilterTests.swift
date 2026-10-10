import XCTest
@testable import DockPeek

final class WindowFilterTests: XCTestCase {
    func testChromeAuxiliaryDialogIsExcludedEvenWithATitle() {
        XCTAssertFalse(WindowFilter.includes(title: "Window", subrole: "AXDialog", bounds: CGRect(x: 10, y: 45, width: 66, height: 20), isMinimized: false))
    }

    func testNormalWindowsDialogsAndMinimizedWindowsArePreserved() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(WindowFilter.includes(title: "Window", subrole: "AXStandardWindow", bounds: bounds, isMinimized: false))
        XCTAssertTrue(WindowFilter.includes(title: "Save", subrole: "AXDialog", bounds: bounds, isMinimized: false))
        XCTAssertTrue(WindowFilter.includes(title: "Document", subrole: "AXStandardWindow", bounds: CGRect(x: 0, y: 0, width: 66, height: 20), isMinimized: true))
        XCTAssertTrue(WindowFilter.includes(title: "Document", subrole: "AXStandardWindow", bounds: .zero, isMinimized: false))
        XCTAssertFalse(WindowFilter.includes(title: "", subrole: "AXUnknown", bounds: bounds, isMinimized: false))
    }
}
