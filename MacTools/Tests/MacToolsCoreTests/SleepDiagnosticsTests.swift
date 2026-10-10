import XCTest
@testable import MacToolsCore

final class SleepDiagnosticsTests: XCTestCase {
    func testParsesBlockersWithoutConfusingUserActivity() {
        let text = """
        Assertion status system-wide:
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 532(powerd): [0x0032c3c100019e0e] 09:36:21 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
           pid 5617(My App): [0x003349670001841b] 00:06:07 NoIdleSleepAssertion named: "Playback"
           pid 96530(caffeinate): [0x002e8b1800059a37] 92:56:14 PreventUserIdleDisplaySleep named: "caffeinate command-line tool"
        \tDetails: caffeinate asserting forever
           pid 598(WindowServer): [0x0033471300098401] 00:00:05 UserIsActive named: "mouse activity"
        No kernel assertions.
        """
        let assertions = SleepDiagnostics.parseAssertions(text)
        XCTAssertEqual(assertions.count, 4)
        XCTAssertEqual(assertions.filter(\.preventsSleep).count, 3)
        XCTAssertEqual(assertions[1].processName, "My App")
        XCTAssertEqual(assertions[2].effect, "Keeping the display awake")
        XCTAssertFalse(assertions[3].preventsSleep)
    }

    func testProcessNamesWithParenthesesAndQuotedEvidence() {
        let text = #" pid 123(Helper (Renderer)): [0x123] 00:00:01 PreventSystemSleep named: "Task "one" is running" "#
        let result = SleepDiagnostics.parseAssertions(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.processName, "Helper (Renderer)")
        XCTAssertEqual(result.first?.detail, #"Task "one" is running"#)
    }

    func testMalformedAssertionsDoNotInventBlockers() {
        XCTAssertTrue(SleepDiagnostics.parseAssertions("pid nonsense\nPreventSystemSleep 1\npid 1(foo): [truncated]").isEmpty)
        XCTAssertTrue(SleepDiagnostics.parseAssertions("No kernel assertions.").isEmpty)
    }

    func testEventsAreNewestFirstBoundedAndExcludeAssertionMentionsOfWake() {
        let text = """
        2026-10-09 12:00:00 -0500 Sleep              Entering Sleep state due to 'Idle Sleep'
        2026-10-09 12:01:00 -0500 DarkWake           DarkWake from Normal Sleep due to RTC/Maintenance Using BATT
        2026-10-09 12:02:00 -0500 Assertions         PID 42 Created PreventSystemSleep "Wake event"
        2026-10-09 12:03:00 -0500 Wake               Wake from Normal Sleep due to EC.LidOpen/Lid Open Using AC
        """
        let events = SleepDiagnostics.parseEvents(text, limit: 2)
        XCTAssertEqual(events.map(\.kind), ["Wake", "DarkWake"])
        XCTAssertEqual(events[0].timestamp, "2026-10-09 12:03:00 -0500")
        XCTAssertTrue(events[0].detail.contains("LidOpen"))
        XCTAssertEqual(events[1].title, "Brief background wake")
        XCTAssertTrue(SleepDiagnostics.parseEvents(text, limit: 0).isEmpty)
    }

    func testTruncatedLogLinesAndDuplicateEventsAreIgnored() {
        let line = "2026-10-09 12:03:00 +0000 Wake Wake from Normal Sleep due to USB"
        let events = SleepDiagnostics.parseEvents("ke from cut-off record\n\(line)\n\(line)\nTotal Sleep/Wakes since boot: 2")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].evidence, line)
    }
}
