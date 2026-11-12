import XCTest
import CoreGraphics
@testable import ScrollSplitCore

final class MouseFeaturesTests: XCTestCase {
    /// Steps a glide at 60 Hz from `start` until well past its duration.
    private func drain(_ axis: inout GlideAxis, from start: Double) -> [Int64] {
        (1...40).map { axis.step(at: start + Double($0) / 60) }
    }

    func testSingleNotchGlidesToExactlyItsDistance() {
        for distance: Int64 in [1, 7, 10, 33, 97, 400, -1, -10, -133] {
            var axis = GlideAxis()
            axis.add(distance, at: 0)
            let steps = drain(&axis, from: 0)
            XCTAssertEqual(steps.reduce(0, +), distance, "\(distance)")
            XCTAssertTrue(axis.isIdle)
            XCTAssertTrue(steps.allSatisfy { $0 == 0 || ($0 > 0) == (distance > 0) }, "never moves backwards")
        }
    }

    func testGlideEasesOutAndFinishesWithinItsDuration() {
        var axis = GlideAxis()
        axis.add(600, at: 0)
        let steps = (1...12).map { axis.step(at: Double($0) / 60) }
        XCTAssertGreaterThan(steps.first!, steps[8], "fast first, slow last")
        XCTAssertEqual(steps.reduce(0, +), 600)
        XCTAssertTrue(axis.isIdle, "done by 0.2 s")
        XCTAssertGreaterThan(steps.filter { $0 != 0 }.count, 5, "a run of events, not a jump")
    }

    func testBurstAddsToTheGlideAndTotalsExactly() {
        var axis = GlideAxis()
        var total: Int64 = 0
        var time = 0.0
        let notches: [Int64] = [40, 40, 13, 80, 40, 1, 40]
        for notch in notches {
            axis.add(notch, at: time)
            time += 0.03
            total += axis.step(at: time)
        }
        XCTAssertFalse(axis.isIdle, "a burst extends the glide instead of finishing it")
        total += drain(&axis, from: time).reduce(0, +)
        XCTAssertEqual(total, notches.reduce(0, +))
    }

    func testBurstDoesNotRestartFromZero() {
        var axis = GlideAxis()
        axis.add(100, at: 0)
        let first = axis.step(at: 0.1)
        axis.add(100, at: 0.1)
        XCTAssertEqual(axis.remaining, 200 - first, "what was owed is carried, not lost or replayed")
    }

    func testReversalStopsTheGlideAtOnce() {
        var axis = GlideAxis()
        axis.add(200, at: 0)
        let before = axis.step(at: 0.03)
        let dropped = axis.add(-50, at: 0.03)
        XCTAssertEqual(dropped, 200 - before, "everything still owed is dropped")
        let after = drain(&axis, from: 0.03)
        XCTAssertTrue(after.allSatisfy { $0 <= 0 }, "nothing more in the old direction")
        XCTAssertEqual(before + dropped + after.reduce(0, +), 200 - 50, "delivered plus dropped equals the notches")
        XCTAssertEqual(after.reduce(0, +), -50, "the reversing notch glides its full distance")
    }

    func testAxesGlideIndependently() {
        var glide = ScrollGlide()
        glide.add(vertical: 30, horizontal: -20, at: 0)
        glide.add(vertical: 0, horizontal: 20, at: 0.02) // horizontal reverses, vertical continues
        var v: Int64 = 0, h: Int64 = 0
        for frame in 1...40 { let step = glide.step(at: 0.02 + Double(frame) / 60); v += step.vertical; h += step.horizontal }
        XCTAssertEqual(v, 30)
        XCTAssertEqual(h, 20)
        XCTAssertTrue(glide.isIdle)
    }

    func testStopDropsEverything() {
        var glide = ScrollGlide()
        glide.add(vertical: 90, horizontal: 0, at: 0)
        glide.stop()
        XCTAssertTrue(glide.isIdle)
        XCTAssertEqual(glide.step(at: 1).vertical, 0)
    }

    func testNotchDistanceUsesPixelsThenTicks() {
        XCTAssertEqual(SmoothScroll.notchDistance(point: 23, tick: 2), 23)
        XCTAssertEqual(SmoothScroll.notchDistance(point: 0, tick: -2), -20)
        XCTAssertEqual(SmoothScroll.notchDistance(point: 0, tick: 0), 0)
    }

    func testOnlyUnmodifiedDiscreteNotchesAreSmoothed() {
        XCTAssertTrue(SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: []))
        XCTAssertTrue(SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: [.maskShift]),
                      "Shift-scroll glides like vertical scrolling")
        XCTAssertTrue(SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: [.maskAlphaShift, .maskNumericPad]))
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, [.maskShift, .maskCommand]] {
            XCTAssertFalse(SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: modifier))
        }
        for enabled in [false, true] { for smooth in [false, true] { for continuous in [false, true] { for own in [false, true] {
            XCTAssertEqual(SmoothScroll.shouldSmooth(enabled: enabled, smoothScrolling: smooth, isContinuous: continuous, isOwnEvent: own, flags: []),
                           enabled && smooth && !continuous && !own)
        } } } }
    }

    func testShiftNotchGlidesHorizontallyWithoutShift() {
        let swapped = SmoothScroll.glideAxes(vertical: 40, horizontal: 0, flags: [.maskShift, .maskAlphaShift])
        XCTAssertEqual(swapped.vertical, 0)
        XCTAssertEqual(swapped.horizontal, 40)
        XCTAssertEqual(swapped.flags, [.maskAlphaShift])
        let alreadyHorizontal = SmoothScroll.glideAxes(vertical: 0, horizontal: -30, flags: [.maskShift])
        XCTAssertEqual(alreadyHorizontal.horizontal, -30, "a notch the system already turned sideways stays sideways")
        XCTAssertEqual(alreadyHorizontal.vertical, 0)
        let plain = SmoothScroll.glideAxes(vertical: 40, horizontal: 5, flags: [])
        XCTAssertEqual(plain.vertical, 40)
        XCTAssertEqual(plain.horizontal, 5)
    }

    func testStalledGlideIsDropped() {
        XCTAssertFalse(SmoothScroll.isStalled(glideIdle: false, lastFrame: 10, now: 10.1))
        XCTAssertTrue(SmoothScroll.isStalled(glideIdle: false, lastFrame: 10, now: 10.5), "no frames for 0.5 s: the display went away")
        XCTAssertFalse(SmoothScroll.isStalled(glideIdle: true, lastFrame: 0, now: 100), "an idle glide is never stalled")
    }

    func testSideButtonsClaimPressAndMatchingReleaseOnly() {
        var router = SideButtonRouter()
        XCTAssertEqual(router.handle(isDown: true, button: 3, enabled: true, isOwnEvent: false), .send(.back))
        XCTAssertEqual(router.handle(isDown: true, button: 4, enabled: true, isOwnEvent: false), .send(.forward))
        XCTAssertEqual(router.handle(isDown: false, button: 3, enabled: true, isOwnEvent: false), .swallow)
        XCTAssertEqual(router.handle(isDown: false, button: 3, enabled: true, isOwnEvent: false), .pass, "a release is swallowed once")
        XCTAssertEqual(router.handle(isDown: false, button: 4, enabled: false, isOwnEvent: false), .swallow,
                       "turning the switch off mid-press still swallows the claimed release")
        for button: Int64 in [0, 1, 2, 5, 6, 31] {
            XCTAssertEqual(router.handle(isDown: true, button: button, enabled: true, isOwnEvent: false), .pass)
            XCTAssertEqual(router.handle(isDown: false, button: button, enabled: true, isOwnEvent: false), .pass)
        }
    }

    func testSideButtonsPassWhenOffOrOwn() {
        var router = SideButtonRouter()
        XCTAssertEqual(router.handle(isDown: true, button: 3, enabled: false, isOwnEvent: false), .pass)
        XCTAssertEqual(router.handle(isDown: false, button: 3, enabled: true, isOwnEvent: false), .pass, "an unclaimed release passes")
        XCTAssertEqual(router.handle(isDown: true, button: 4, enabled: true, isOwnEvent: true), .pass)
        _ = router.handle(isDown: true, button: 3, enabled: true, isOwnEvent: false)
        router.reset()
        XCTAssertEqual(router.handle(isDown: false, button: 3, enabled: true, isOwnEvent: false), .pass)
    }

    func testNavigationKeys() {
        XCTAssertEqual(NavigationCommand.back.keyCode, 0x21)
        XCTAssertEqual(NavigationCommand.forward.keyCode, 0x1E)
        XCTAssertEqual(NavigationCommand.back.character, "[")
        XCTAssertEqual(NavigationCommand.forward.character, "]")
    }

    func testMouseFilterExcludesTrackpads() {
        XCTAssertTrue(MouseServiceFilter.isMouse(conformsToMouse: true, conformsToTouchPad: false, isBuiltIn: false, product: "USB Optical Mouse"))
        XCTAssertFalse(MouseServiceFilter.isMouse(conformsToMouse: true, conformsToTouchPad: true, isBuiltIn: false, product: "Mouse"))
        XCTAssertFalse(MouseServiceFilter.isMouse(conformsToMouse: true, conformsToTouchPad: false, isBuiltIn: true, product: nil))
        XCTAssertFalse(MouseServiceFilter.isMouse(conformsToMouse: true, conformsToTouchPad: false, isBuiltIn: false, product: "Magic Trackpad"))
        XCTAssertFalse(MouseServiceFilter.isMouse(conformsToMouse: false, conformsToTouchPad: false, isBuiltIn: false, product: "Keyboard"))
    }

    func testReapplyingKeepsTheTrueOriginal() {
        var ledger = AccelerationLedger()
        XCTAssertTrue(ledger.linearize(device: 7, current: 45_056))
        XCTAssertFalse(ledger.linearize(device: 7, current: AccelerationLedger.linear), "already linear on wake: nothing to write")
        XCTAssertTrue(ledger.linearize(device: 7, current: 90_000), "the system reset it: write again")
        XCTAssertEqual(ledger.restorations(fallback: 1), [7: 45_056], "the first original wins")
        XCTAssertTrue(ledger.originals.isEmpty && ledger.touched.isEmpty)
    }

    func testOnlyTouchedDevicesAreRestored() {
        var ledger = AccelerationLedger()
        XCTAssertFalse(ledger.linearize(device: 1, current: AccelerationLedger.linear), "the user's own linear setting is left alone")
        XCTAssertTrue(ledger.linearize(device: 2, current: nil))
        XCTAssertEqual(ledger.restorations(fallback: 30_000), [2: 30_000], "unknown original falls back to the system preference")
    }

    func testSystemScalingAsFixedPoint() {
        XCTAssertEqual(AccelerationLedger.fixedPoint(scaling: 0.6875), 45_056)
        XCTAssertEqual(AccelerationLedger.fixedPoint(scaling: 3), 196_608)
        XCTAssertEqual(AccelerationLedger.fixedPoint(scaling: -1), AccelerationLedger.linear)
        XCTAssertEqual(AccelerationLedger.fixedPoint(scaling: nil), 45_056)
        XCTAssertEqual(AccelerationLedger.fixedPoint(scaling: .nan), 45_056)
    }

    // MARK: Bridge

    func testNewSwitchesDefaultOff() {
        let settings = ScrollSettings()
        XCTAssertFalse(settings.smoothScrolling)
        XCTAssertFalse(settings.sideButtonsNavigate)
        XCTAssertFalse(settings.mouseAccelerationOff)
    }

    func testNewKeysValidateAsBooleans() throws {
        let patch = try SettingsPatch(data: Data(#"{"smoothScrolling":true,"sideButtonsNavigate":false,"mouseAccelerationOff":true}"#.utf8))
        XCTAssertEqual(patch.values["smoothScrolling"] as? Bool, true)
        XCTAssertEqual(patch.values["mouseAccelerationOff"] as? Bool, true)
        for json in [#"{"smoothScrolling":1}"#, #"{"sideButtonsNavigate":"true"}"#, #"{"mouseAccelerationOff":null}"#,
                     #"{"enabled":true,"smoothScrolling":0.5}"#] {
            XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8)), json)
        }
    }

    func testOldPatchStillValidates() throws {
        let patch = try SettingsPatch(data: Data(#"{"enabled":true,"reverseVertical":false,"reverseHorizontal":true,"speedMultiplier":2,"launchAtLogin":false}"#.utf8))
        XCTAssertEqual(patch.values.count, 5)
    }

    func testReadOnlyAvailabilityKeyIsRejected() {
        for json in [#"{"mouseAccelerationAvailable":true}"#, #"{"mouseAccelerationAvailable":false}"#,
                     #"{"smoothScrolling":true,"mouseAccelerationAvailable":true}"#] {
            XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8)), json)
        }
    }

    func testAccelerationCannotBeTurnedOnWhenUnavailable() throws {
        XCTAssertThrowsError(try SettingsPatch(data: Data(#"{"smoothScrolling":true,"mouseAccelerationOff":true}"#.utf8), mouseAccelerationAvailable: false))
        _ = try SettingsPatch(data: Data(#"{"mouseAccelerationOff":false}"#.utf8), mouseAccelerationAvailable: false)
        _ = try SettingsPatch(data: Data(#"{"mouseAccelerationOff":true}"#.utf8), mouseAccelerationAvailable: true)
    }
}
