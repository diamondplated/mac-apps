import XCTest

@testable import ScreenWren

final class FocusRestorationTests: XCTestCase {
    @MainActor func testExplicitCancellationRestoresThePreviousAppOnlyOnce() {
        var activations = 0
        let focus = SelectionFocusRestoration { activations += 1 }
        focus.restore()
        focus.restore()
        XCTAssertEqual(activations, 1)
    }

    @MainActor func testApplicationSwitchCancellationPreservesTheChosenApp() {
        var activations = 0
        let focus = SelectionFocusRestoration { activations += 1 }
        // Resignation discards restoration before invoking the selector's cancellation callback.
        focus.discard()
        focus.restore()
        XCTAssertEqual(activations, 0)
    }

    @MainActor func testPreviousSelectorCannotDiscardTheNextSelectorsRestoration() {
        var activatedApps: [String] = []
        let previous = SelectionFocusRestoration { activatedApps.append("previous") }
        let current = SelectionFocusRestoration { activatedApps.append("current") }
        previous.discard()
        previous.restore()
        current.restore()
        XCTAssertEqual(activatedApps, ["current"])
    }
}
