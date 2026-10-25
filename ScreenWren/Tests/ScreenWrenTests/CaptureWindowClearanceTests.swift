import AppKit
import XCTest

@testable import ScreenWren

final class CaptureWindowClearanceTests: XCTestCase {
    @MainActor private func shownWindow(level: NSWindow.Level = .normal) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = level
        window.orderFrontRegardless()
        return window
    }

    @MainActor func testOnlyVisibleOrdinaryWindowsObstructTheSelector() {
        let editor = shownWindow()
        let pin = shownWindow(level: .floating)
        let overlay = shownWindow()
        let hidden = shownWindow()
        hidden.orderOut(nil)
        defer { [editor, pin, overlay].forEach { $0.orderOut(nil) } }
        let obstructing = CaptureWindowClearance.obstructingWindows([editor, pin, overlay, hidden], excluding: [overlay])
        XCTAssertEqual(obstructing.map(ObjectIdentifier.init), [ObjectIdentifier(editor)])
    }

    @MainActor func testClearingHidesOrdinaryWindowsUntilRestored() {
        let editor = shownWindow()
        let pin = shownWindow(level: .floating)
        defer { [editor, pin].forEach { $0.orderOut(nil) } }
        let clearance = CaptureWindowClearance()
        clearance.clear(excluding: [], orderedWindows: [editor, pin], appIsActive: false)
        XCTAssertFalse(editor.isVisible)
        XCTAssertTrue(pin.isVisible, "Pinned captures stay where the user put them")
        clearance.restore(appIsActive: false)
        XCTAssertTrue(editor.isVisible)
        clearance.restore(appIsActive: false)
        XCTAssertTrue(editor.isVisible)
    }

    @MainActor func testSelectorKeepsThePreviousEditorOutOfTheWayUntilItFinishes() throws {
        let editor = shownWindow()
        defer { editor.orderOut(nil) }
        let screen = try XCTUnwrap(NSScreen.main)
        var finished = false
        let controller = SelectionWindowController(screen: screen, prompt: "Test", allowsWindows: false) { _ in
            finished = true
        }
        controller.show()
        XCTAssertFalse(editor.isVisible, "Starting a capture must not leave the old editor over the target")
        controller.cancel()
        XCTAssertTrue(finished)
        XCTAssertTrue(editor.isVisible, "The editor comes back once the selector is gone")
    }
}
