import XCTest
import CoreGraphics
@testable import DockPeek

final class DockClickRouterTests: XCTestCase {
    private let app = DockHit(subrole: DockHit.applicationSubrole, runningPID: 7)
    private let other = DockHit(subrole: DockHit.applicationSubrole, runningPID: 8)
    private let notRunning = DockHit(subrole: DockHit.applicationSubrole, runningPID: nil)
    private let point = CGPoint(x: 500, y: 1050)

    private func router(hide: Bool = false, scroll: Bool = false, middle: Bool = false) -> DockClickRouter {
        var router = DockClickRouter()
        router.settings = DockClickSettings(hidesFrontApp: hide, scrollCyclesWindows: scroll, middleClickOpensWindow: middle)
        return router
    }

    /// A press and release on `hit`, returning the release's decision.
    private func click(
        _ router: inout DockClickRouter, hit: DockHit?, flags: CGEventFlags = [], clicks: Int64 = 1,
        held: TimeInterval = 0.1, moved: CGFloat = 0, front: pid_t? = 7, visible: Bool = true
    ) -> (down: DockClickDecision, up: DockClickDecision) {
        let down = router.decide(.leftDown(clickCount: clicks), flags: flags, location: point, time: 10, hit: hit, frontmostPID: front, frontAppHasVisibleWindow: visible)
        let end = CGPoint(x: point.x + moved, y: point.y)
        if moved > 0 { _ = router.decide(.leftDragged, flags: flags, location: end, time: 10 + held / 2, hit: nil, frontmostPID: front) }
        let up = router.decide(.leftUp, flags: flags, location: end, time: 10 + held, hit: nil, frontmostPID: front)
        return (down, up)
    }

    func testPlainClickOnTheFrontAppHidesItAndPassesTheClick() {
        var router = router(hide: true)
        XCTAssertTrue(router.needsHitTest(.leftDown(clickCount: 1), flags: []))
        let result = click(&router, hit: app)
        XCTAssertEqual(result.down, .pass)
        XCTAssertEqual(result.up, DockClickDecision(consume: false, action: .hide(7)))
    }

    func testEveryOtherClickPassesThroughUntouched() {
        let cases: [(String, (inout DockClickRouter) -> DockClickDecision)] = [
            ("another app's icon", { self.click(&$0, hit: self.other).up }),
            ("command click", { self.click(&$0, hit: self.app, flags: .maskCommand).up }),
            ("option click", { self.click(&$0, hit: self.app, flags: .maskAlternate).up }),
            ("control click", { self.click(&$0, hit: self.app, flags: .maskControl).up }),
            ("shift click", { self.click(&$0, hit: self.app, flags: .maskShift).up }),
            ("double click", { self.click(&$0, hit: self.app, clicks: 2).up }),
            ("click and hold", { self.click(&$0, hit: self.app, held: 0.8).up }),
            ("drag", { self.click(&$0, hit: self.app, moved: 30).up }),
            ("Trash", { self.click(&$0, hit: DockHit(subrole: "AXTrashDockItem", runningPID: nil)).up }),
            ("folder", { self.click(&$0, hit: DockHit(subrole: "AXFolderDockItem", runningPID: nil)).up }),
            ("minimized window tile", { self.click(&$0, hit: DockHit(subrole: "AXMinimizedWindowDockItem", runningPID: 7)).up }),
            ("app not running", { self.click(&$0, hit: self.notRunning).up }),
            ("nothing under the pointer", { self.click(&$0, hit: nil).up }),
            ("all windows minimized", { self.click(&$0, hit: self.app, visible: false).up })
        ]
        for (name, run) in cases {
            var router = router(hide: true)
            XCTAssertEqual(run(&router), .pass, name)
        }
    }

    func testModifiedOrRepeatedPressesNeverCostAHitTest() {
        let router = router(hide: true)
        XCTAssertFalse(router.needsHitTest(.leftDown(clickCount: 1), flags: .maskCommand))
        XCTAssertFalse(router.needsHitTest(.leftDown(clickCount: 2), flags: []))
        XCTAssertFalse(router.needsHitTest(.leftUp, flags: []))
        XCTAssertFalse(router.needsHitTest(.leftDragged, flags: []))
    }

    func testRightClicksAreNeverTapped() {
        let all = DockClickSettings(hidesFrontApp: true, scrollCyclesWindows: true, middleClickOpensWindow: true)
        let types = DockClickController.eventTypes(for: all)
        XCTAssertFalse(types.contains(.rightMouseDown))
        XCTAssertFalse(types.contains(.rightMouseUp))
        XCTAssertEqual(DockClickController.eventTypes(for: DockClickSettings()), [])
        XCTAssertEqual(DockClickController.eventTypes(for: DockClickSettings(scrollCyclesWindows: true)), [.scrollWheel])
    }

    func testSwitchedOffActionsPassEverything() {
        var router = router()
        XCTAssertFalse(router.needsHitTest(.leftDown(clickCount: 1), flags: []))
        XCTAssertFalse(router.needsHitTest(.otherDown(button: 2), flags: []))
        XCTAssertFalse(router.needsHitTest(.scroll, flags: []))
        XCTAssertEqual(click(&router, hit: app).up, .pass)
        XCTAssertEqual(router.decide(.otherDown(button: 2), flags: [], location: point, time: 0, hit: app, frontmostPID: 7), .pass)
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 0, hit: app, frontmostPID: 7, scrollSample: wheel(-1, at: 0)), .pass)
    }

    func testMiddleClickOnARunningAppOpensAWindowAndSwallowsTheRelease() {
        var router = router(middle: true)
        XCTAssertTrue(router.needsHitTest(.otherDown(button: 2), flags: []))
        XCTAssertEqual(router.decide(.otherDown(button: 2), flags: [], location: point, time: 0, hit: other, frontmostPID: 7), DockClickDecision(consume: true, action: .newWindow(8)))
        XCTAssertEqual(router.decide(.otherUp(button: 2), flags: [], location: point, time: 0.1, hit: nil, frontmostPID: 7), DockClickDecision(consume: true, action: nil))
        // Only that one release.
        XCTAssertEqual(router.decide(.otherUp(button: 2), flags: [], location: point, time: 0.2, hit: nil, frontmostPID: 7), .pass)
    }

    func testMiddleClickPassThroughCases() {
        var router = router(middle: true)
        XCTAssertFalse(router.needsHitTest(.otherDown(button: 3), flags: []))
        XCTAssertFalse(router.needsHitTest(.otherDown(button: 2), flags: .maskCommand))
        XCTAssertEqual(router.decide(.otherDown(button: 2), flags: [], location: point, time: 0, hit: notRunning, frontmostPID: 7), .pass)
        XCTAssertEqual(router.decide(.otherDown(button: 2), flags: [], location: point, time: 0, hit: DockHit(subrole: "AXTrashDockItem", runningPID: nil), frontmostPID: 7), .pass)
        XCTAssertEqual(router.decide(.otherDown(button: 3), flags: [], location: point, time: 0, hit: app, frontmostPID: 7), .pass)
        XCTAssertEqual(router.decide(.otherUp(button: 2), flags: [], location: point, time: 0.1, hit: nil, frontmostPID: 7), .pass)
    }

    func testScrollOverAnAppCyclesAndElsewherePasses() {
        var router = router(scroll: true)
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 0, hit: app, frontmostPID: 7, scrollSample: wheel(-1, at: 0)), DockClickDecision(consume: true, action: .cycle(7, direction: 1)))
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 1, hit: app, frontmostPID: 7, scrollSample: wheel(1, at: 1)), DockClickDecision(consume: true, action: .cycle(7, direction: -1)))
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 2, hit: nil, frontmostPID: 7, scrollSample: wheel(-1, at: 2)), .pass)
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 3, hit: notRunning, frontmostPID: 7, scrollSample: wheel(-1, at: 3)), .pass)
        XCTAssertEqual(router.decide(.scroll, flags: [], location: point, time: 4, hit: DockHit(subrole: "AXFolderDockItem", runningPID: nil), frontmostPID: 7, scrollSample: wheel(-1, at: 4)), .pass)
    }

    private func wheel(_ delta: Double, at time: TimeInterval) -> ScrollStepAccumulator.Sample {
        .init(deltaY: delta, deltaX: 0, isContinuous: false, phase: 0, momentumPhase: 0, time: time)
    }
}

final class ScrollStepAccumulatorTests: XCTestCase {
    private func pad(_ delta: Double, _ time: TimeInterval, phase: Int64 = 2, momentum: Int64 = 0) -> ScrollStepAccumulator.Sample {
        .init(deltaY: delta, deltaX: 0, isContinuous: true, phase: phase, momentumPhase: momentum, time: time)
    }

    func testOneTrackpadGestureIsOneStep() {
        var scroll = ScrollStepAccumulator()
        var steps: [Int] = []
        if let step = scroll.add(pad(0, 0, phase: ScrollStepAccumulator.Phase.began), pid: 1) { steps.append(step) }
        // A long smooth swipe: 60 events of 4 points, far past the threshold.
        for index in 1...60 {
            if let step = scroll.add(pad(-4, Double(index) * 0.008), pid: 1) { steps.append(step) }
        }
        for index in 1...40 {
            if let step = scroll.add(pad(-8, 0.5 + Double(index) * 0.016, phase: 0, momentum: 2), pid: 1) { steps.append(step) }
        }
        _ = scroll.add(pad(0, 1.2, phase: ScrollStepAccumulator.Phase.ended), pid: 1)
        XCTAssertEqual(steps, [1])

        // The next gesture steps again, the other way.
        _ = scroll.add(pad(0, 2, phase: ScrollStepAccumulator.Phase.began), pid: 1)
        var next: [Int] = []
        for index in 1...10 {
            if let step = scroll.add(pad(5, 2 + Double(index) * 0.01), pid: 1) { next.append(step) }
        }
        XCTAssertEqual(next, [-1])
    }

    func testSmallTrackpadNudgesDoNotStep() {
        var scroll = ScrollStepAccumulator()
        _ = scroll.add(pad(0, 0, phase: ScrollStepAccumulator.Phase.began), pid: 1)
        XCTAssertNil(scroll.add(pad(-10, 0.01), pid: 1))
        XCTAssertNil(scroll.add(pad(-10, 0.02), pid: 1))
        XCTAssertNil(scroll.add(pad(0, 0.03, phase: ScrollStepAccumulator.Phase.ended), pid: 1))
    }

    func testWheelNotchesStepButAFastSpinIsRateLimited() {
        var scroll = ScrollStepAccumulator()
        func notch(_ time: TimeInterval) -> Int? {
            scroll.add(.init(deltaY: -1, deltaX: 0, isContinuous: false, phase: 0, momentumPhase: 0, time: time), pid: 1)
        }
        XCTAssertEqual(notch(0), 1)
        XCTAssertNil(notch(0.02))
        XCTAssertNil(notch(0.05))
        XCTAssertEqual(notch(0.2), 1)
        XCTAssertNil(scroll.add(.init(deltaY: 0, deltaX: 0, isContinuous: false, phase: 0, momentumPhase: 0, time: 1), pid: 1))
    }

    func testHorizontalScrollingCountsOnSideDocks() {
        var scroll = ScrollStepAccumulator()
        XCTAssertEqual(scroll.add(.init(deltaY: 0, deltaX: 1, isContinuous: false, phase: 0, momentumPhase: 0, time: 0), pid: 1), -1)
    }
}

final class WindowCycleTests: XCTestCase {
    func testCyclesInAStableOrder() {
        var cycle = WindowCycle()
        // Raising a window moves it to the front of the app's own list; the cycle must not bounce.
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 20, 30], appIsFrontmost: true, direction: 1, now: 0), 20)
        XCTAssertEqual(cycle.step(pid: 1, windows: [20, 10, 30], appIsFrontmost: true, direction: 1, now: 0.3), 30)
        XCTAssertEqual(cycle.step(pid: 1, windows: [30, 20, 10], appIsFrontmost: true, direction: 1, now: 0.6), 10)
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 30, 20], appIsFrontmost: true, direction: -1, now: 0.9), 30)
    }

    func testABackgroundAppComesForwardWithItsFrontWindowFirst() {
        var cycle = WindowCycle()
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 20], appIsFrontmost: false, direction: 1, now: 0), 10)
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 20], appIsFrontmost: true, direction: 1, now: 0.2), 20)
    }

    func testANewSessionStartsAfterAPauseOrAnotherApp() {
        var cycle = WindowCycle()
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 20, 30], appIsFrontmost: true, direction: 1, now: 0), 20)
        XCTAssertEqual(cycle.step(pid: 1, windows: [20, 10, 30], appIsFrontmost: true, direction: 1, now: 5), 10)
        XCTAssertEqual(cycle.step(pid: 2, windows: [40, 50], appIsFrontmost: true, direction: 1, now: 5.1), 50)
    }

    func testClosedWindowsDropOut() {
        var cycle = WindowCycle()
        XCTAssertEqual(cycle.step(pid: 1, windows: [10, 20, 30], appIsFrontmost: true, direction: 1, now: 0), 20)
        XCTAssertEqual(cycle.step(pid: 1, windows: [20, 10], appIsFrontmost: true, direction: 1, now: 0.2), 10)
        XCTAssertNil(cycle.step(pid: 1, windows: [], appIsFrontmost: true, direction: 1, now: 0.4))
    }
}

final class DockZoneTests: XCTestCase {
    private let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1440, height: 900)]

    func testOnlyPointsNearABottomOrSideEdgeQualify() {
        XCTAssertTrue(DockZone.contains(CGPoint(x: 900, y: 1070), screens: screens))
        XCTAssertTrue(DockZone.contains(CGPoint(x: 10, y: 500), screens: screens))
        XCTAssertTrue(DockZone.contains(CGPoint(x: 3350, y: 400), screens: screens))
        XCTAssertFalse(DockZone.contains(CGPoint(x: 900, y: 500), screens: screens))
        XCTAssertFalse(DockZone.contains(CGPoint(x: 900, y: 5), screens: screens))
        XCTAssertFalse(DockZone.contains(CGPoint(x: -50, y: 500), screens: screens))
    }
}
