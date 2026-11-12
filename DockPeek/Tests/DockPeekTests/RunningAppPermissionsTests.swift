import XCTest
@testable import DockPeek

final class RunningAppPermissionsTests: XCTestCase {
    private let own = URL(fileURLWithPath: "/Applications/DockPeek.app")
    private let other = URL(fileURLWithPath: "/tmp/elsewhere/DockPeek.app")

    func testSoleMatchingCopyIsFoundAndOwnProcessIsIgnored() {
        let copies = [RunningCopy(pid: 10, bundleURL: own), RunningCopy(pid: 99, bundleURL: own)]
        XCTAssertEqual(RunningAppPermissions.soleMatchingCopy(among: copies, ownURL: own, ownPID: 99)?.pid, 10)
    }

    func testDifferentOrAmbiguousOrAbsentCopiesAreNotTrusted() {
        XCTAssertNil(RunningAppPermissions.soleMatchingCopy(among: [], ownURL: own, ownPID: 1))
        XCTAssertNil(RunningAppPermissions.soleMatchingCopy(among: [RunningCopy(pid: 10, bundleURL: other)], ownURL: own, ownPID: 1))
        XCTAssertNil(RunningAppPermissions.soleMatchingCopy(among: [RunningCopy(pid: 10, bundleURL: nil)], ownURL: own, ownPID: 1))
        let twins = [RunningCopy(pid: 10, bundleURL: own), RunningCopy(pid: 11, bundleURL: own)]
        XCTAssertNil(RunningAppPermissions.soleMatchingCopy(among: twins, ownURL: own, ownPID: 1))
    }

    func testReportAsksOnlyTheSoleMatchingCopy() {
        var asked: [pid_t] = []
        let value = RunningAppPermissions.report(copies: [RunningCopy(pid: 10, bundleURL: own), RunningCopy(pid: 11, bundleURL: other)], ownURL: own, ownPID: 1) { pid in
            asked.append(pid); return ["accessibility": true, "screenRecording": false]
        }
        XCTAssertEqual(asked, [10])
        XCTAssertEqual(value, ["accessibility": true, "screenRecording": false])
        asked = []
        let twins = [RunningCopy(pid: 10, bundleURL: own), RunningCopy(pid: 11, bundleURL: own)]
        XCTAssertNil(RunningAppPermissions.report(copies: twins, ownURL: own, ownPID: 1) { _ in asked.append(0); return [:] })
        XCTAssertTrue(asked.isEmpty)
    }

    func testReplyMustComeFromTheAskedProcessWithBothBooleans() {
        let good: [AnyHashable: Any] = ["pid": NSNumber(value: 10), "permissions": ["accessibility": true, "screenRecording": true]]
        XCTAssertEqual(RunningAppPermissions.parse(good, expectedPID: 10), ["accessibility": true, "screenRecording": true])
        XCTAssertNil(RunningAppPermissions.parse(good, expectedPID: 11))
        XCTAssertNil(RunningAppPermissions.parse(["pid": NSNumber(value: 10), "permissions": ["accessibility": true]], expectedPID: 10))
        XCTAssertNil(RunningAppPermissions.parse(nil, expectedPID: 10))
    }

    func testSnapshotCarriesRunningAppValuesAndProvenance() throws {
        let suite = "DockPeekTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let current = ["accessibility": false, "screenRecording": false]
        let running = ["accessibility": true, "screenRecording": true]

        let live = ToolPreferences(defaults: defaults, permissionState: { current }, runningAppPermissions: { running })
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(live.snapshot(loginStatus: .notRegistered))) as? [String: Any])
        XCTAssertEqual(json["permissionsSource"] as? String, "runningApp")
        XCTAssertEqual(json["permissions"] as? [String: Bool], running)

        let fallback = ToolPreferences(defaults: defaults, permissionState: { current }, runningAppPermissions: { nil })
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback.snapshot(loginStatus: .notRegistered))) as? [String: Any])
        XCTAssertEqual(json["permissionsSource"] as? String, "currentProcess")
        XCTAssertEqual(json["permissions"] as? [String: Bool], current)
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
    }
}
