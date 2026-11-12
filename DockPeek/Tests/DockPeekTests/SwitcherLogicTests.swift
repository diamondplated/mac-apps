import XCTest
import CoreGraphics
@testable import DockPeek

final class SwitcherOrderingTests: XCTestCase {
    private let big = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func server(_ id: CGWindowID, _ pid: pid_t, title: String? = nil, onScreen: Bool = true) -> SwitcherServerWindow {
        SwitcherServerWindow(id: id, pid: pid, title: title, bounds: big, isOnScreen: onScreen)
    }

    private func ax(_ id: CGWindowID, _ pid: pid_t, _ title: String, minimized: Bool = false, subrole: String = "AXStandardWindow", bounds: CGRect? = nil) -> SwitcherAXWindow {
        SwitcherAXWindow(id: id, pid: pid, title: title, subrole: subrole, bounds: bounds ?? big, isMinimized: minimized)
    }

    func testFrontToBackAcrossAppsWithMinimizedLast() {
        let order = SwitcherOrdering.order(
            serverWindows: [server(10, 1), server(20, 2), server(11, 1, onScreen: false), server(30, 3)],
            axWindows: [
                1: [ax(10, 1, "Editor"), ax(11, 1, "Notes", minimized: true)],
                2: [ax(20, 2, "Inbox")],
                3: [ax(30, 3, "Terminal")]
            ],
            axApps: [1, 2, 3]
        )
        XCTAssertEqual(order.map(\.id), [10, 20, 30, 11])
        XCTAssertEqual(order.map(\.isMinimized), [false, false, false, true])
        XCTAssertEqual(order.first?.axIndex, 0)
        XCTAssertEqual(order.last?.axIndex, 1)
    }

    func testOnScreenSurfacesAccessibilityOmitsAreSkipped() {
        // A browser's helper surface: listed by the window server, unknown to Accessibility.
        let order = SwitcherOrdering.order(
            serverWindows: [server(5, 1, title: "Helper"), server(6, 1)],
            axWindows: [1: [ax(6, 1, "Page")]],
            axApps: [1]
        )
        XCTAssertEqual(order.map(\.id), [6])
    }

    func testOtherSpaceWindowsNeedATitle() {
        let order = SwitcherOrdering.order(
            serverWindows: [server(7, 1, title: "On Another Space", onScreen: false), server(8, 1, onScreen: false), server(9, 1, title: "  ", onScreen: false)],
            axWindows: [1: []],
            axApps: [1]
        )
        XCTAssertEqual(order.map(\.id), [7])
        XCTAssertNil(order.first?.axIndex)
    }

    func testAppsWithoutAccessibilityKeepTitledWindows() {
        let order = SwitcherOrdering.order(
            serverWindows: [server(4, 9, title: "Legacy"), server(3, 9)],
            axWindows: [:],
            axApps: []
        )
        XCTAssertEqual(order.map(\.id), [4])
    }

    func testDockPreviewFilterAppliesAndOwnWindowsAreExcluded() {
        let tiny = CGRect(x: 0, y: 0, width: 66, height: 20)
        let order = SwitcherOrdering.order(
            serverWindows: [server(1, 1), server(2, 1), server(3, 42)],
            axWindows: [
                1: [ax(1, 1, "Window", subrole: "AXDialog", bounds: tiny), ax(2, 1, "", subrole: "AXUnknown")],
                42: [ax(3, 42, "DockPeek")]
            ],
            axApps: [1, 42],
            excluding: 42
        )
        XCTAssertEqual(order, [])
    }

    func testMinimizedWindowsMissingFromTheServerListAreAppended() {
        let order = SwitcherOrdering.order(
            serverWindows: [server(1, 1)],
            axWindows: [1: [ax(1, 1, "Open"), ax(0, 1, "Minimized", minimized: true)]],
            axApps: [1]
        )
        XCTAssertEqual(order.map(\.title), ["Open", "Minimized"])
    }

    func testCurrentWindowIsTheFrontmostAppsFirstWindow() {
        let windows = [
            SwitcherCandidate(id: 1, pid: 1, title: "A", isMinimized: false, axIndex: 0),
            SwitcherCandidate(id: 2, pid: 2, title: "B", isMinimized: false, axIndex: 0)
        ]
        XCTAssertEqual(SwitcherOrdering.currentIndex(of: windows, frontmostPID: 1), 0)
        // The frontmost app has no window (or is DockPeek): the first step lands on the first card.
        XCTAssertNil(SwitcherOrdering.currentIndex(of: windows, frontmostPID: 3))
        XCTAssertNil(SwitcherOrdering.currentIndex(of: [], frontmostPID: 1))
    }
}

final class SwitcherSelectionTests: XCTestCase {
    func testStepWrapsBothWays() {
        XCTAssertEqual(SwitcherSelection.step(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(SwitcherSelection.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(SwitcherSelection.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(SwitcherSelection.step(from: 1, by: 7, count: 3), 2)
        XCTAssertNil(SwitcherSelection.step(from: 0, by: 1, count: 0))
    }

    func testStepFromNoHighlight() {
        XCTAssertEqual(SwitcherSelection.step(from: nil, by: 1, count: 4), 0)
        XCTAssertEqual(SwitcherSelection.step(from: nil, by: 2, count: 4), 1)
        XCTAssertEqual(SwitcherSelection.step(from: nil, by: -1, count: 4), 3)
        XCTAssertEqual(SwitcherSelection.step(from: nil, by: -2, count: 4), 2)
    }

    func testRowsMoveByColumnsWithoutWrapping() {
        // 7 windows in 3 columns: rows [0 1 2] [3 4 5] [6].
        XCTAssertEqual(SwitcherSelection.row(from: 1, by: 1, columns: 3, count: 7), 4)
        XCTAssertEqual(SwitcherSelection.row(from: 4, by: -1, columns: 3, count: 7), 1)
        XCTAssertEqual(SwitcherSelection.row(from: 1, by: -1, columns: 3, count: 7), 1)
        XCTAssertEqual(SwitcherSelection.row(from: 5, by: 1, columns: 3, count: 7), 6)
        XCTAssertEqual(SwitcherSelection.row(from: 6, by: 1, columns: 3, count: 7), 6)
    }
}

final class SwitcherSessionTests: XCTestCase {
    func testQuickOptionTabSwitchesToThePreviousWindowWithoutThePanel() {
        var session = SwitcherSession(forward: true)
        XCTAssertEqual(session.load(count: 4, currentIndex: 0), .wait)
        XCTAssertEqual(session.commit(), 1)
        XCTAssertFalse(session.wasShown)
        // A late show-delay timer must not bring the panel up after the switch.
        XCTAssertFalse(session.showDelayElapsed())
    }

    func testReleaseBeforeTheListArrivesSwitchesOnArrival() {
        var session = SwitcherSession(forward: true)
        XCTAssertNil(session.commit())
        XCTAssertEqual(session.load(count: 3, currentIndex: 0), .switchNow(1))
        XCTAssertFalse(session.wasShown)
    }

    func testReleaseBeforeArrivalWithNoWindowsDoesNothing() {
        var session = SwitcherSession(forward: true)
        XCTAssertNil(session.commit())
        XCTAssertEqual(session.load(count: 0, currentIndex: nil), .switchNow(nil))
    }

    func testHoldingShowsThePanelAfterTheDelay() {
        var session = SwitcherSession(forward: true)
        _ = session.load(count: 3, currentIndex: 0)
        XCTAssertTrue(session.showDelayElapsed())
        XCTAssertTrue(session.wasShown)
        session.move(by: 1)
        XCTAssertEqual(session.commit(), 2)
    }

    func testDelayElapsedWhileLoadingShowsOnArrival() {
        var session = SwitcherSession(forward: true)
        XCTAssertFalse(session.showDelayElapsed())
        XCTAssertEqual(session.load(count: 3, currentIndex: 0), .show)
        XCTAssertTrue(session.wasShown)
    }

    func testTabsPressedBeforeTheListArriveAreKept() {
        var session = SwitcherSession(forward: true)
        session.move(by: 1)
        session.move(by: 1)
        _ = session.load(count: 5, currentIndex: 0)
        XCTAssertEqual(session.highlight, 3)
    }

    func testShiftTabStartsFromTheEnd() {
        var session = SwitcherSession(forward: false)
        _ = session.load(count: 4, currentIndex: 0)
        XCTAssertEqual(session.highlight, 3)
        session.move(by: 1)
        XCTAssertEqual(session.highlight, 0)
    }

    func testNoCurrentWindowStartsOnTheFirstCard() {
        var session = SwitcherSession(forward: true)
        _ = session.load(count: 4, currentIndex: nil)
        XCTAssertEqual(session.highlight, 0)
    }

    func testCancelSwitchesNowhere() {
        var session = SwitcherSession(forward: true)
        _ = session.load(count: 4, currentIndex: 0)
        session.cancel()
        XCTAssertNil(session.commit())
    }

    func testSelectingACardOverridesTheHighlight() {
        var session = SwitcherSession(forward: true)
        _ = session.load(count: 4, currentIndex: 0)
        session.select(3)
        XCTAssertEqual(session.commit(), 3)
    }
}

final class SwitcherKeyRouterTests: XCTestCase {
    typealias Key = SwitcherKeyRouter.Key
    private let option: CGEventFlags = .maskAlternate

    func testOptionTabBeginsAndIsConsumed() {
        var router = SwitcherKeyRouter()
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: option), .init(consume: true, action: .begin(forward: true)))
        XCTAssertTrue(router.isActive)
        XCTAssertEqual(router.handle(kind: .keyUp, keyCode: Key.tab, flags: option), .init(consume: true, action: nil))
    }

    func testOptionShiftTabBeginsBackward() {
        var router = SwitcherKeyRouter()
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskShift]).action, .begin(forward: false))
    }

    func testEverythingElsePassesWhileIdle() {
        var router = SwitcherKeyRouter()
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: []), .pass)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskCommand]), .pass)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskControl]), .pass)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.escape, flags: option), .pass)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.right, flags: option), .pass)
        XCTAssertEqual(router.handle(kind: .keyUp, keyCode: Key.tab, flags: option), .pass)
        XCTAssertEqual(router.handle(kind: .flagsChanged, keyCode: 58, flags: []), .pass)
        XCTAssertFalse(router.isActive)
    }

    func testNavigationWhileActive() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: option).action, .step(1))
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskShift]).action, .step(-1))
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.right, flags: option).action, .step(1))
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.left, flags: option).action, .step(-1))
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.down, flags: option).action, .row(1))
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.up, flags: option), .init(consume: true, action: .row(-1)))
        // Other keys reach the app untouched.
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: 0, flags: option), .pass)
    }

    func testReleasingOptionCommitsWithoutSwallowingTheModifier() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        XCTAssertEqual(router.handle(kind: .flagsChanged, keyCode: 58, flags: [.maskAlternate, .maskShift]), .pass)
        XCTAssertEqual(router.handle(kind: .flagsChanged, keyCode: 58, flags: []), .init(consume: false, action: .commit))
        XCTAssertFalse(router.isActive)
        // The next plain Tab is an ordinary Tab again.
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: []), .pass)
    }

    func testEscapeCancels() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.escape, flags: option), .init(consume: true, action: .cancel))
        XCTAssertFalse(router.isActive)
        XCTAssertEqual(router.handle(kind: .keyUp, keyCode: Key.escape, flags: option).consume, true)
        XCTAssertEqual(router.handle(kind: .keyUp, keyCode: Key.escape, flags: option), .pass)
    }

    func testMissedOptionReleaseFailsOpen() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        // A key arrives without Option: we missed the release. Commit and let the key through.
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: []), .init(consume: false, action: .commit))
        XCTAssertFalse(router.isActive)
    }

    func testResetForgetsKeyUpsItWasWaitingFor() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        router.reset()
        // The Tab release was missed; the next ordinary Tab's release must reach the app.
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.tab, flags: []), .pass)
        XCTAssertEqual(router.handle(kind: .keyUp, keyCode: Key.tab, flags: []), .pass)
    }

    func testResetEndsTheSession() {
        var router = SwitcherKeyRouter()
        _ = router.handle(kind: .keyDown, keyCode: Key.tab, flags: option)
        router.reset()
        XCTAssertEqual(router.handle(kind: .keyDown, keyCode: Key.right, flags: option), .pass)
    }
}

final class SwitcherLayoutTests: XCTestCase {
    func testOneRowWhenTheWindowsFit() {
        let layout = SwitcherLayout(count: 3, availableSize: CGSize(width: 1600, height: 900))
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertFalse(layout.scrolls)
        XCTAssertEqual(layout.size.width, 3 * SwitcherLayout.cardSize.width + 2 * SwitcherLayout.spacing + 2 * SwitcherLayout.inset)
    }

    func testWrapsToMoreRows() {
        let layout = SwitcherLayout(count: 11, availableSize: CGSize(width: 1200, height: 900))
        XCTAssertEqual(layout.columns, 5)
        XCTAssertEqual(layout.rows, 3)
        XCTAssertFalse(layout.scrolls)
        XCTAssertLessThanOrEqual(layout.size.width, 1200)
    }

    func testScrollsBeyondTheScreen() {
        let layout = SwitcherLayout(count: 40, availableSize: CGSize(width: 1200, height: 600))
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.size.height, 600)
    }

    func testNarrowScreensStillGetOneColumn() {
        let layout = SwitcherLayout(count: 2, availableSize: CGSize(width: 100, height: 900))
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.rows, 2)
    }
}
