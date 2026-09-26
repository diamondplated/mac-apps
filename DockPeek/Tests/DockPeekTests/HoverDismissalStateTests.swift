import XCTest
@testable import DockPeek

final class HoverDismissalStateTests: XCTestCase {
    private let dockFrame = CGRect(x: 400, y: 0, width: 64, height: 64)
    private let panelFrame = CGRect(x: 250, y: 78, width: 400, height: 205)
    private var state = HoverDismissalState()

    private func shouldDismiss(_ point: CGPoint, at time: TimeInterval) -> Bool {
        state.shouldDismiss(
            pointer: point, dockFrame: dockFrame, previewFrame: panelFrame, now: time
        )
    }

    func testStationaryPointerOutsideDismissesWithoutAnExitEvent() {
        XCTAssertFalse(shouldDismiss(CGPoint(x: 450, y: 150), at: 0))

        // The periodic sampler sees departure even if AppKit never delivers mouseExited.
        let outside = CGPoint(x: 800, y: 400)
        XCTAssertFalse(shouldDismiss(outside, at: 1))
        XCTAssertFalse(shouldDismiss(outside, at: 1.5))
        XCTAssertTrue(shouldDismiss(outside, at: 1.7))
    }

    func testEmptySpaceInFormerTransitCorridorDoesNotKeepPreviewOpen() {
        // Both locations were inside the old expanded union of the Dock and panel.
        for outside in [CGPoint(x: 300, y: 40), CGPoint(x: 655, y: 150)] {
            state.reset()
            XCTAssertFalse(shouldDismiss(outside, at: 0))
            XCTAssertTrue(shouldDismiss(outside, at: 0.7))
        }
    }

    func testContinuousOutsideMovementDoesNotPostponeDismissal() {
        XCTAssertFalse(shouldDismiss(CGPoint(x: 800, y: 400), at: 0))
        XCTAssertFalse(shouldDismiss(CGPoint(x: 820, y: 420), at: 0.2))
        XCTAssertFalse(shouldDismiss(CGPoint(x: 840, y: 440), at: 0.4))
        XCTAssertTrue(shouldDismiss(CGPoint(x: 860, y: 460), at: 0.7))
    }

    func testDockAndPreviewRemainOpenWhileActuallyHovered() {
        for inside in [CGPoint(x: 432, y: 32), CGPoint(x: 450, y: 150)] {
            state.reset()
            XCTAssertFalse(shouldDismiss(inside, at: 0))
            XCTAssertFalse(shouldDismiss(inside, at: 60))
        }
    }

    func testReturningToDockOrPreviewCancelsEarlierDeparture() {
        let outside = CGPoint(x: 800, y: 400)
        for inside in [CGPoint(x: 432, y: 32), CGPoint(x: 450, y: 150)] {
            state.reset()
            XCTAssertFalse(shouldDismiss(outside, at: 0))
            XCTAssertFalse(shouldDismiss(inside, at: 0.4))
            XCTAssertFalse(shouldDismiss(outside, at: 0.5))
            XCTAssertFalse(shouldDismiss(outside, at: 0.9))
            XCTAssertTrue(shouldDismiss(outside, at: 1.2))
        }
    }

    func testCrossingGapWorksForBottomLeftAndRightDocks() {
        let layouts: [(dock: CGRect, panel: CGRect, gap: CGPoint)] = [
            (dockFrame, panelFrame, CGPoint(x: 432, y: 70)),
            (CGRect(x: 0, y: 400, width: 64, height: 64),
             CGRect(x: 78, y: 330, width: 400, height: 205), CGPoint(x: 70, y: 432)),
            (CGRect(x: 1000, y: 400, width: 64, height: 64),
             CGRect(x: 586, y: 330, width: 400, height: 205), CGPoint(x: 993, y: 432))
        ]

        for layout in layouts {
            state.reset()
            let samples: [(point: CGPoint, time: TimeInterval)] = [
                (CGPoint(x: layout.dock.midX, y: layout.dock.midY), 0),
                (layout.gap, 0.1),
                (layout.gap, 0.5),
                (CGPoint(x: layout.panel.midX, y: layout.panel.midY), 0.6),
                (CGPoint(x: layout.panel.midX, y: layout.panel.midY), 5)
            ]
            for sample in samples {
                XCTAssertFalse(state.shouldDismiss(
                    pointer: sample.point, dockFrame: layout.dock,
                    previewFrame: layout.panel, now: sample.time
                ))
            }
        }
    }

    func testStoppingInGapEventuallyDismisses() {
        let gap = CGPoint(x: 432, y: 70)
        XCTAssertFalse(shouldDismiss(gap, at: 0))
        XCTAssertTrue(shouldDismiss(gap, at: 0.7))
    }

    func testHiddenOrMovedPreviewDoesNotLeaveStaleHover() {
        let pointer = CGPoint(x: 450, y: 150)
        let movedPanel = panelFrame.offsetBy(dx: 700, dy: 0)
        for newFrame: CGRect? in [nil, movedPanel] {
            state.reset()
            XCTAssertFalse(shouldDismiss(pointer, at: 0))
            XCTAssertFalse(state.shouldDismiss(
                pointer: pointer, dockFrame: dockFrame, previewFrame: newFrame, now: 1
            ))
            XCTAssertTrue(state.shouldDismiss(
                pointer: pointer, dockFrame: dockFrame, previewFrame: newFrame, now: 1.7
            ))
        }
    }

    func testResetGivesNextHoverItsOwnGracePeriod() {
        let outside = CGPoint(x: 800, y: 400)
        XCTAssertFalse(shouldDismiss(outside, at: 0))
        state.reset()
        XCTAssertFalse(shouldDismiss(outside, at: 10))
        XCTAssertFalse(shouldDismiss(outside, at: 10.5))
        XCTAssertTrue(shouldDismiss(outside, at: 10.7))
    }

    func testNegativeScreenCoordinatesUseSameDismissalRules() {
        let secondaryDock = dockFrame.offsetBy(dx: -1500, dy: -900)
        let secondaryPanel = panelFrame.offsetBy(dx: -1500, dy: -900)
        XCTAssertFalse(state.shouldDismiss(
            pointer: CGPoint(x: secondaryPanel.midX, y: secondaryPanel.midY),
            dockFrame: secondaryDock, previewFrame: secondaryPanel, now: 0
        ))
        let outside = CGPoint(x: -700, y: -500)
        XCTAssertFalse(state.shouldDismiss(
            pointer: outside, dockFrame: secondaryDock, previewFrame: secondaryPanel, now: 1
        ))
        XCTAssertTrue(state.shouldDismiss(
            pointer: outside, dockFrame: secondaryDock, previewFrame: secondaryPanel, now: 1.7
        ))
    }
}
