import XCTest
@testable import ScrollSplitCore

final class ScrollSplitTests: XCTestCase {
    func testContinuousAndSelfGeneratedEventsAlwaysPassThrough() {
        XCTAssertTrue(WheelClassifier.shouldTransform(isContinuous: false, enabled: true, isOwnEvent: false))
        for continuous in [false, true] { for enabled in [false, true] { for own in [false, true] {
            XCTAssertEqual(WheelClassifier.shouldTransform(isContinuous: continuous, enabled: enabled, isOwnEvent: own), enabled && !continuous && !own)
        } } }
    }
    func testFractionalTicksAccumulateBothDirections() {
        for factor in [0.25, -0.25, 0.5, -0.5, 1.25, -1.25, 4.0, -4.0] {
            var accumulator = WheelAccumulator()
            let output = (0..<40).map { _ in accumulator.scale(1, factor: factor) }.reduce(0, +)
            XCTAssertEqual(Double(output), 40 * factor)
        }
    }
    func testDirectionChangeDoesNotCarryOppositeRemainder() {
        var accumulator = WheelAccumulator()
        XCTAssertEqual(accumulator.scale(1, factor: 0.75), 0)
        XCTAssertEqual(accumulator.scale(-1, factor: 0.75), 0)
        XCTAssertEqual(accumulator.scale(-1, factor: 0.75), -1)
    }
    func testZeroEventDoesNotDrainRemainderAndResetClearsIt() {
        var accumulator = WheelAccumulator()
        XCTAssertEqual(accumulator.scale(1, factor: 0.5), 0)
        XCTAssertEqual(accumulator.scale(0, factor: 0.5), 0)
        XCTAssertEqual(accumulator.scale(1, factor: 0.5), 1)
        _ = accumulator.scale(1, factor: 0.5)
        accumulator.reset()
        XCTAssertEqual(accumulator.scale(1, factor: 0.5), 0)
    }
    func testValidationRejectsWholeInvalidPatch() throws {
        for json in ["{\"enabled\":1}", "{\"speedMultiplier\":true}", "{\"speedMultiplier\":4.1}", "{\"speedMultiplier\":0.2}", "{\"speedMultiplier\":\"2\"}", "{\"enabled\":true,\"permissions\":{}}", "{\"reverseHorizontal\":null}", "[]"] {
            XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8)), json)
        }
        let patch = try SettingsPatch(data: Data("{\"enabled\":true,\"speedMultiplier\":0.25,\"reverseHorizontal\":false}".utf8))
        XCTAssertEqual(patch.values["enabled"] as? Bool, true)
        XCTAssertEqual(patch.values["speedMultiplier"] as? Double, 0.25)
    }
    func testExtremeDeltaClamps() {
        var accumulator = WheelAccumulator()
        XCTAssertEqual(accumulator.scale(Int64.max, factor: 4), Int64(Int32.max))
        XCTAssertEqual(accumulator.scale(Int64.min, factor: 4), Int64(Int32.min))
    }
}

import CoreGraphics
extension ScrollSplitTests {
    func testRealQuartzFieldsPreserveFlagsAndUnselectedAxes() throws {
        for vertical in [true, false] {
            var settings = ScrollSettings()
            settings.enabled = true
            settings.reverseVertical = vertical
            settings.reverseHorizontal = !vertical
            var transformer = WheelTransformer(settings: settings)
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 3, wheel1: 2, wheel2: -3, wheel3: 7))
            event.flags = [.maskShift, .maskAlternate]
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            event.setIntegerValueField(.eventSourceUserData, value: 123)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.5)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -0.25)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 12)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -18)
            transformer.transform(event)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), vertical ? -2 : 2)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), vertical ? -3 : 3)
            XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), vertical ? -0.5 : 0.5)
            XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), vertical ? -0.25 : 0.25)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), vertical ? -12 : 12)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), vertical ? -18 : 18)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis3), 7)
            XCTAssertEqual(event.flags, [.maskShift, .maskAlternate])
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 123)
        }
    }
    func testContinuousAndOwnQuartzEventsUnmodified() throws {
        for own in [true, false] {
            var settings = ScrollSettings(); settings.enabled = true; settings.speedMultiplier = 4
            var transformer = WheelTransformer(settings: settings)
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 2, wheel2: -3, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: own ? 0 : 1)
            event.setIntegerValueField(.eventSourceUserData, value: own ? WheelTransformer.ownMarker : 0)
            transformer.transform(event)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 2)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), -3)
        }
    }
}
