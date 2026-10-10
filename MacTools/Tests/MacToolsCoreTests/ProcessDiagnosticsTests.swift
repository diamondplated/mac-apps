import Foundation
import XCTest
@testable import MacToolsCore

final class ProcessDiagnosticsTests: XCTestCase {
    func testParsesExecutableWithSpacesAndConvertsRSS() throws {
        let rows = ProcessDiagnostics.parse("  81 501 125.4 2048 /Applications/Useful App.app/Contents/MacOS/Useful App\n82 0 0.0 0 kernel_task\n")
        XCTAssertEqual(rows.count, 2)
        let sample = try XCTUnwrap(rows.first)
        XCTAssertEqual(sample.identity.pid, 81)
        XCTAssertEqual(sample.identity.uid, 501)
        XCTAssertEqual(sample.identity.executable, "/Applications/Useful App.app/Contents/MacOS/Useful App")
        XCTAssertEqual(sample.cpuPercent, 125.4)
        XCTAssertEqual(sample.residentBytes, 2_097_152)
    }

    func testSkipsMalformedOverflowAndDuplicateRows() {
        let rows = ProcessDiagnostics.parse("""
        PID UID CPU RSS COMM
        1 501 nan 42 app
        2 501 -1 42 app
        3 -2 4 42 app
        4 501 4 18446744073709551615 app
        0 501 4 42 app
        5 501 4 42
        6 501 4 42 good
        6 501 20 52 duplicate
        """)
        XCTAssertEqual(rows.map(\.identity.pid), [6])
    }

    private let start = Date(timeIntervalSince1970: 1_000)
    private func sample(cpu: Double = 60, pid: Int32 = 42, uid: UInt32 = 501,
                        path: String = "/Applications/Test.app/Contents/MacOS/Test", launch: Double = 100) -> ProcessSample {
        .init(identity: .init(pid: pid, uid: uid, executable: path, launchDate: Date(timeIntervalSince1970: launch)), cpuPercent: cpu, residentBytes: 1024)
    }

    func testRequiresThreeSeparatedHighReadingsAndClearsWhenBelowThreshold() {
        var tracker = SustainedCPUTracker()
        XCTAssertTrue(tracker.observe([sample()], at: start, threshold: 50, interval: 5).isEmpty)
        XCTAssertTrue(tracker.observe([sample()], at: start.addingTimeInterval(5), threshold: 50, interval: 5).isEmpty)
        XCTAssertEqual(tracker.observe([sample()], at: start.addingTimeInterval(10), threshold: 50, interval: 5), [sample().identity])
        XCTAssertTrue(tracker.observe([sample(cpu: 49)], at: start.addingTimeInterval(15), threshold: 50, interval: 5).isEmpty)
        XCTAssertTrue(tracker.observe([sample()], at: start.addingTimeInterval(20), threshold: 50, interval: 5).isEmpty)
    }

    func testRapidRefreshDoesNotFabricateSustainedActivity() {
        var tracker = SustainedCPUTracker()
        for offset in [0.0, 0.1, 0.2, 0.3, 1, 2, 3] {
            XCTAssertTrue(tracker.observe([sample()], at: start.addingTimeInterval(offset), threshold: 50, interval: 5).isEmpty)
        }
    }

    func testUnknownGenerationCannotClaimSustainedActivity() {
        var tracker = SustainedCPUTracker()
        var unknown = sample()
        unknown.identity.launchDate = nil
        for offset in [0.0, 5, 10, 15] {
            XCTAssertTrue(tracker.observe([unknown], at: start.addingTimeInterval(offset), threshold: 50, interval: 5).isEmpty)
        }
    }

    func testMissingProcessGapAndPIDReuseEachBreakStreak() {
        for replacement in [sample(launch: 200), sample(uid: 502), sample(path: "/bin/different")] {
            var tracker = SustainedCPUTracker()
            _ = tracker.observe([sample()], at: start, threshold: 50, interval: 5)
            _ = tracker.observe([sample()], at: start.addingTimeInterval(5), threshold: 50, interval: 5)
            XCTAssertTrue(tracker.observe([replacement], at: start.addingTimeInterval(10), threshold: 50, interval: 5).isEmpty)
        }
        var tracker = SustainedCPUTracker()
        _ = tracker.observe([sample()], at: start, threshold: 50, interval: 5)
        _ = tracker.observe([sample()], at: start.addingTimeInterval(5), threshold: 50, interval: 5)
        _ = tracker.observe([], at: start.addingTimeInterval(10), threshold: 50, interval: 5)
        XCTAssertTrue(tracker.observe([sample()], at: start.addingTimeInterval(15), threshold: 50, interval: 5).isEmpty)
        XCTAssertTrue(tracker.observe([sample()], at: start.addingTimeInterval(40), threshold: 50, interval: 5).isEmpty)
    }

    func testQuitRequiresSameGenerationOwnerBundleAndExcludesSelf() {
        let identity = sample().identity
        func allowed(_ current: ProcessIdentity, bundle: String? = "com.test.app", owner: UInt32 = 501, selfPID: Int32 = 999) -> Bool {
            ProcessDiagnostics.canQuit(expected: identity, current: current, expectedBundleID: "com.test.app",
                                       currentBundleID: bundle, currentUID: owner, ownPID: selfPID)
        }
        XCTAssertTrue(allowed(identity))
        XCTAssertFalse(allowed(sample(launch: 200).identity))
        XCTAssertFalse(allowed(sample(uid: 502).identity))
        XCTAssertFalse(allowed(sample(path: "/bin/other").identity))
        XCTAssertFalse(allowed(identity, bundle: "com.other.app"))
        XCTAssertFalse(allowed(identity, bundle: nil))
        XCTAssertFalse(allowed(identity, owner: 502))
        XCTAssertFalse(allowed(identity, selfPID: 42))
        var unknownGeneration = identity
        unknownGeneration.launchDate = nil
        XCTAssertFalse(ProcessDiagnostics.canQuit(expected: unknownGeneration, current: unknownGeneration,
                                                expectedBundleID: "com.test.app", currentBundleID: "com.test.app", currentUID: 501, ownPID: 999))
    }
}
