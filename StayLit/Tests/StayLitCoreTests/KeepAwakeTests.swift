import XCTest
@testable import StayLitCore

final class KeepAwakeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "h:mm a"
        return formatter
    }

    private func sentence(_ state: KeepAwakeState, at time: Date? = nil) -> String? {
        let time = time ?? now
        return AwakeSentence.sentence(for: state.reason(at: time), now: time, timeFormatter: formatter)
    }

    func testNothingActiveIsNotAwake() {
        let state = KeepAwakeState()
        XCTAssertFalse(state.shouldBeAwake(at: now))
        XCTAssertNil(state.reason(at: now))
        XCTAssertNil(sentence(state))
        XCTAssertEqual(AwakeSentence.idleTitle(endedForLowBattery: false), "Not Keeping Awake")
    }

    func testManualReason() {
        var state = KeepAwakeState()
        state.turnOnManually()
        XCTAssertTrue(state.shouldBeAwake(at: now))
        XCTAssertEqual(state.reason(at: now), .manual)
        XCTAssertEqual(sentence(state), "Awake until you turn it off")
        XCTAssertNil(state.nextDeadline(after: now), "a manual keep-awake has no end of its own")
    }

    func testTimedReasonCountsDownAndExpires() {
        var state = KeepAwakeState()
        state.keepAwake(for: 30 * 60, from: now)
        XCTAssertEqual(sentence(state), "Awake for 30 more minutes")
        XCTAssertEqual(sentence(state, at: now.addingTimeInterval(18 * 60 + 30)), "Awake for 12 more minutes", "a part minute rounds up")
        XCTAssertEqual(sentence(state, at: now.addingTimeInterval(29 * 60 + 30)), "Awake for 1 more minute")
        XCTAssertEqual(state.nextDeadline(after: now), now.addingTimeInterval(30 * 60))
        // At the deadline the timer is over, and settling drops it.
        let end = now.addingTimeInterval(30 * 60)
        XCTAssertFalse(state.shouldBeAwake(at: end))
        state.settle(at: end, power: .mains)
        XCTAssertNil(state.until)
        XCTAssertNil(state.nextDeadline(after: end))
    }

    func testLongTimerSaysWhenItEnds() {
        var state = KeepAwakeState()
        state.keepAwake(for: 2 * 3600, from: now)
        XCTAssertEqual(sentence(state), "Awake until \(formatter.string(from: now.addingTimeInterval(7200)))")
        XCTAssertEqual(sentence(state, at: now.addingTimeInterval(3600 + 18 * 60)), "Awake for 42 more minutes")
    }

    func testTimedAndManualReplaceEachOther() {
        var state = KeepAwakeState()
        state.turnOnManually()
        state.keepAwake(for: 3600, from: now)
        XCTAssertFalse(state.manual)
        XCTAssertEqual(state.reason(at: now), .timed(until: now.addingTimeInterval(3600)))
        state.turnOnManually()
        XCTAssertNil(state.until)
        state.turnOffUserKeepAwake()
        XCTAssertFalse(state.userKeepAwakeIsOn(at: now))
    }

    func testAppListFollowsLaunchAndQuit() {
        var state = KeepAwakeState()
        state.apps = ["com.apple.dt.Xcode", "com.apple.FinalCut"]
        state.running.launched(pid: 10, bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertFalse(state.shouldBeAwake(at: now), "an app not on the list keeps nothing awake")
        state.running.launched(pid: 11, bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        XCTAssertEqual(sentence(state), "Awake while Xcode is running")
        state.running.launched(pid: 12, bundleIdentifier: "com.apple.FinalCut", name: "Final Cut Pro")
        XCTAssertEqual(sentence(state), "Awake while Xcode and Final Cut Pro are running")
        state.running.terminated(pid: 11)
        XCTAssertEqual(sentence(state), "Awake while Final Cut Pro is running")
        state.running.terminated(pid: 12)
        XCTAssertFalse(state.shouldBeAwake(at: now), "back to normal when the last listed app quits")
    }

    func testSecondCopyQuittingKeepsReason() {
        var state = KeepAwakeState()
        state.apps = ["com.example.render"]
        state.running.launched(pid: 20, bundleIdentifier: "com.example.render", name: "Render")
        state.running.launched(pid: 21, bundleIdentifier: "com.example.render", name: "Render")
        state.running.terminated(pid: 21)
        XCTAssertTrue(state.shouldBeAwake(at: now))
        state.running.terminated(pid: 20)
        XCTAssertFalse(state.shouldBeAwake(at: now))
        state.running.launched(pid: 22, bundleIdentifier: nil, name: "No Bundle")
        XCTAssertTrue(state.running.byProcess.isEmpty)
    }

    func testManyAppsSummarise() {
        var state = KeepAwakeState()
        state.apps = ["a.one", "a.two", "a.three"]
        for (index, id) in state.apps.enumerated() { state.running.launched(pid: Int32(index), bundleIdentifier: id, name: id.uppercased()) }
        XCTAssertEqual(sentence(state), "Awake while A.ONE and 2 other apps are running")
    }

    func testManualOutranksTimerOutranksApps() {
        var state = KeepAwakeState()
        state.apps = ["com.apple.dt.Xcode"]
        state.running.launched(pid: 1, bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        state.keepAwake(for: 600, from: now)
        XCTAssertEqual(sentence(state), "Awake for 10 more minutes")
        state.turnOnManually()
        XCTAssertEqual(sentence(state), "Awake until you turn it off")
        state.turnOffUserKeepAwake()
        XCTAssertEqual(sentence(state), "Awake while Xcode is running")
    }

    func testBatteryCutoffEndsManualAndTimedButNotApps() {
        for timed in [false, true] {
            var state = KeepAwakeState()
            if timed { state.keepAwake(for: 3600, from: now) } else { state.turnOnManually() }
            state.apps = ["com.apple.dt.Xcode"]
            XCTAssertFalse(state.settle(at: now, power: PowerSource(onBattery: true, percent: 20)), "20 percent is not below 20")
            XCTAssertFalse(state.settle(at: now, power: PowerSource(onBattery: false, percent: 5)), "charging never cuts off")
            XCTAssertFalse(state.settle(at: now, power: PowerSource(onBattery: true, percent: nil)))
            XCTAssertTrue(state.shouldBeAwake(at: now))
            XCTAssertTrue(state.settle(at: now, power: PowerSource(onBattery: true, percent: 19)))
            XCTAssertFalse(state.shouldBeAwake(at: now))
            XCTAssertTrue(state.endedForLowBattery)
            XCTAssertEqual(AwakeSentence.idleTitle(endedForLowBattery: state.endedForLowBattery), "Keep Awake Ended at Low Battery")
            XCTAssertFalse(state.settle(at: now, power: PowerSource(onBattery: true, percent: 10)), "nothing left to end")
            // The app list is not a user switch, so low battery leaves it alone.
            state.running.launched(pid: 3, bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
            XCTAssertFalse(state.settle(at: now, power: PowerSource(onBattery: true, percent: 10)))
            XCTAssertTrue(state.shouldBeAwake(at: now))
            XCTAssertTrue(state.endedForLowBattery, "the notice stays while still on battery")
            state.settle(at: now, power: PowerSource(onBattery: false, percent: 12))
            XCTAssertFalse(state.endedForLowBattery, "plugging in clears the notice")
            state.endedForLowBattery = true
            state.turnOnManually()
            XCTAssertFalse(state.endedForLowBattery)
            state.endedForLowBattery = true
            state.turnOffUserKeepAwake()
            XCTAssertFalse(state.endedForLowBattery)
        }
    }
}

final class FakePowerService: PowerService {
    var next: UInt32 = 1
    var fail = false
    var held: [UInt32: AssertionKind] = [:]
    var takes: [AssertionKind] = []
    var releases: [UInt32] = []
    func takeAssertion(_ kind: AssertionKind, reason: String) -> UInt32? {
        guard !fail else { return nil }
        takes.append(kind)
        defer { next += 1 }
        held[next] = kind
        return next
    }
    func releaseAssertion(_ id: UInt32) {
        XCTAssertNotNil(held.removeValue(forKey: id), "released an assertion that was not held")
        releases.append(id)
    }
}

final class AssertionKeeperTests: XCTestCase {
    func testTakenOnceAndReleasedWhenTheLastReasonEnds() {
        let service = FakePowerService()
        let keeper = AssertionKeeper(service: service)
        keeper.update(nil)
        XCTAssertTrue(service.takes.isEmpty, "no reason, no assertion")
        keeper.update(.system)
        keeper.update(.system)
        keeper.update(.system)
        XCTAssertEqual(service.takes, [.system], "taken once however often the answer repeats")
        keeper.update(nil)
        XCTAssertEqual(service.releases, [1])
        XCTAssertTrue(service.held.isEmpty)
        keeper.update(nil)
        XCTAssertEqual(service.releases, [1], "released exactly once")
    }

    func testDriveFromStateReleasesWhenLastAppQuits() {
        let service = FakePowerService()
        let keeper = AssertionKeeper(service: service)
        var state = KeepAwakeState()
        state.apps = ["a.b", "c.d"]
        let now = Date()
        func sync() { keeper.update(state.shouldBeAwake(at: now) ? .system : nil) }
        state.running.launched(pid: 1, bundleIdentifier: "a.b", name: "AB"); sync()
        state.running.launched(pid: 2, bundleIdentifier: "c.d", name: "CD"); sync()
        state.running.terminated(pid: 1); sync()
        XCTAssertEqual(service.held.count, 1)
        state.running.terminated(pid: 2); sync()
        XCTAssertEqual(service.takes.count, 1)
        XCTAssertEqual(service.releases.count, 1)
        XCTAssertTrue(service.held.isEmpty)
    }

    func testSwitchingDisplayKindNeverDropsAndReleaseAllOnQuit() {
        let service = FakePowerService()
        let keeper = AssertionKeeper(service: service)
        keeper.update(.system)
        keeper.update(.display)
        XCTAssertEqual(service.takes, [.system, .display])
        XCTAssertEqual(service.releases, [1], "the old one goes only after the new one is held")
        XCTAssertEqual(keeper.held?.kind, .display)
        keeper.releaseAll()
        XCTAssertTrue(service.held.isEmpty)
        XCTAssertNil(keeper.held)
    }

    func testFailedTakeKeepsWhatIsHeldAndRetries() {
        let service = FakePowerService()
        let keeper = AssertionKeeper(service: service)
        keeper.update(.system)
        service.fail = true
        keeper.update(.display)
        XCTAssertEqual(keeper.held?.kind, .system)
        XCTAssertTrue(service.releases.isEmpty)
        service.fail = false
        keeper.update(.display)
        XCTAssertEqual(keeper.held?.kind, .display)
        XCTAssertEqual(service.held.count, 1)
    }

    func testDeinitReleases() {
        let service = FakePowerService()
        var keeper: AssertionKeeper? = AssertionKeeper(service: service)
        keeper?.update(.display)
        keeper = nil
        XCTAssertTrue(service.held.isEmpty)
    }
}
