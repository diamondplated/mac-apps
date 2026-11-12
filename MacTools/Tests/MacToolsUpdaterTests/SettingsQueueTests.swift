import Foundation
import MacToolsCore
import XCTest
@testable import MacTools

@MainActor
final class SettingsQueueTests: XCTestCase {
    /// A stand-in for an installed app's settings command: it merges each patch into its
    /// stored settings, records the order patches arrived in, and can be told to fail.
    @MainActor final class FakeApp {
        var stored: [String: Any]
        var received: [[String: Any]] = []
        var failNext = false
        var delay: UInt64 = 30_000_000

        init(_ app: ManagedApp, _ values: [String: Any] = [:]) {
            stored = ["schemaVersion": 1, "app": app.rawValue, "launchAtLogin": false, "loginStatus": "notRegistered"]
            stored.merge(values) { _, new in new }
        }

        func write(_ patch: Data) async throws -> Data {
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
            received.append(values)
            try await Task.sleep(nanoseconds: delay)
            if failNext { failNext = false; throw AppManagerError.message("rejected") }
            stored.merge(values) { _, new in new }
            return try JSONSerialization.data(withJSONObject: stored)
        }
    }

    private func make(_ app: ManagedApp, _ values: [String: Any] = [:]) throws -> (LibraryModel, ToolSettingsModel, FakeApp) {
        let library = LibraryModel()
        library.settingsApp = app
        let fake = FakeApp(app, values)
        let model = library.toolSettings
        model.writeOverride = { _, patch in try await fake.write(patch) }
        model.snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: fake.stored))
        return (library, model, fake)
    }

    func testChangesMadeInQuickSuccessionApplyInTheOrderTheyWereMade() async throws {
        let (library, model, fake) = try make(.scrollSplit, ["reverseVertical": false])
        // Tasks made on the main actor start in the order they were made, like taps do.
        // (`async let` children may start in any order, which is not what is being tested.)
        let changes = [true, false, true].map { value in
            Task { await model.save(["reverseVertical": value], app: .scrollSplit, library: library) }
        }
        var results: [Bool] = []
        for change in changes { results.append(await change.value) }
        XCTAssertEqual(results, [true, true, true])
        XCTAssertEqual(fake.received.map { $0["reverseVertical"] as? Bool }, [true, false, true])
        XCTAssertEqual(model.snapshot?.reverseVertical, true)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertFalse(model.saving)
    }

    func testTheNewestChoiceStaysOnScreenUntilItsOwnWriteFinishes() async throws {
        let (library, model, _) = try make(.dockPeek, ["dismissalDelay": 0.6])
        let first = Task { await model.save(["dismissalDelay": 1.0], app: .dockPeek, library: library) }
        let second = Task { await model.save(["dismissalDelay": 2.0], app: .dockPeek, library: library) }
        await Task.yield()
        XCTAssertEqual(model.pending["dismissalDelay"] as? Double, 2.0)
        _ = await first.value
        // The first write is done, but the later choice is still what the control shows.
        XCTAssertEqual(model.pending["dismissalDelay"] as? Double, 2.0)
        _ = await second.value
        XCTAssertNil(model.pending["dismissalDelay"])
        XCTAssertEqual(model.snapshot?.dismissalDelay, 2.0)
    }

    func testListEditsBuildOnTheLatestSavedListNotTheOneOnScreenWhenClicked() async throws {
        let presets = ["A", "B", "C"].map { ["name": $0, "width": 100, "height": 100] as [String: Any] }
        let (library, model, fake) = try make(.screenWren, ["presets": presets])
        func remove(_ name: String) -> Task<Bool, Never> {
            Task {
                await model.save(app: .screenWren, library: library) { latest in
                    let kept = (latest?.presets ?? []).filter { $0.name != name }
                    return ["presets": kept.map { ["name": $0.name, "width": $0.width, "height": $0.height] }]
                }
            }
        }
        let first = remove("A"), second = remove("B")
        _ = await (first.value, second.value)
        XCTAssertEqual(model.snapshot?.presets?.map(\.name), ["C"])
        XCTAssertEqual(fake.received.count, 2)
    }

    func testAChangeIsStillWrittenAfterMovingToAnotherAppsPage() async throws {
        let (library, model, fake) = try make(.scrollSplit, ["enabled": false])
        let save = Task { await model.save(["enabled": true], app: .scrollSplit, library: library) }
        // The task has not started yet, so the page changes before the write is attempted.
        library.settingsApp = .dockPeek
        let accepted = await save.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(fake.stored["enabled"] as? Bool, true)
        // The page showing now belongs to another app, so its snapshot is not replaced.
        XCTAssertEqual(model.snapshot?.app, "scrollSplit")
        XCTAssertEqual(model.snapshot?.enabled, false)
    }

    func testAFailedChangeIsReportedAndDoesNotStopTheNextOne() async throws {
        let (library, model, fake) = try make(.scrollSplit, ["enabled": false, "reverseHorizontal": false])
        fake.failNext = true
        let first = Task { await model.save(["enabled": true], app: .scrollSplit, library: library) }
        let second = Task { await model.save(["reverseHorizontal": true], app: .scrollSplit, library: library) }
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, [false, true])
        XCTAssertEqual(library.error, "rejected")
        XCTAssertEqual(model.snapshot?.enabled, false)
        XCTAssertEqual(model.snapshot?.reverseHorizontal, true)
    }

    func testRuleEditsMadeWhileASaveIsInFlightAreKept() {
        let model = ToolSettingsModel()
        let sent = [BrowserRouteRule(domain: "example.com", browserIdentifier: "com.apple.Safari")]
        model.acceptSavedRoutes([])
        model.routeRules = sent
        // The user keeps typing while the save is on its way.
        model.routeRules.append(BrowserRouteRule(domain: "later.example", browserIdentifier: "com.apple.Safari"))
        model.routesSaved(sent, sent: sent)
        XCTAssertEqual(model.routeRules.map(\.domain), ["example.com", "later.example"])
        XCTAssertTrue(model.hasUnsavedRoutes)
        model.discardRouteChanges()
        XCTAssertEqual(model.routeRules, sent)
    }

    func testLoadingASnapshotFillsTheDraftsWithoutOverwritingUnsavedRules() throws {
        let model = ToolSettingsModel()
        let draft = BrowserRouteRule(domain: "draft.example", browserIdentifier: "com.apple.Safari")
        model.routeRules = [draft]
        let json: [String: Any] = [
            "schemaVersion": 1, "app": "linkRoutes", "launchAtLogin": false, "loginStatus": "notRegistered",
            "rules": [["id": "1", "domain": "saved.example", "includeSubdomains": true, "browserIdentifier": "com.apple.Safari"]],
        ]
        model.snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(model.routeRules, [draft])
        model.discardRouteChanges()
        model.snapshot = model.snapshot
        XCTAssertEqual(model.routeRules.map(\.domain), ["saved.example"])
    }

    func testAPermissionHasAStatusOnlyWhenTheRunningAppReportedIt() throws {
        for (source, expected) in [("runningApp", Bool?.some(true)), ("currentProcess", nil), (nil, nil)] as [(String?, Bool?)] {
            var json: [String: Any] = [
                "schemaVersion": 1, "app": "dockPeek", "launchAtLogin": false, "loginStatus": "notRegistered",
                "permissions": ["accessibility": true],
            ]
            if let source { json["permissionsSource"] = source }
            let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(snapshot.permission("accessibility"), expected)
            XCTAssertNil(snapshot.permission("screenRecording"))
        }
    }

    func testAppPageLinks() throws {
        for app in ManagedApp.allCases { XCTAssertEqual(ManagedApp(deepLink: app.deepLink), app) }
        XCTAssertEqual(ManagedApp(deepLink: try XCTUnwrap(URL(string: "MacTools://APP/sift"))), .sift)
        for bad in ["mactools://app/", "mactools://app/unknown", "mactools://other/sift", "mactools://app/sift/extra", "https://app/sift"] {
            XCTAssertNil(ManagedApp(deepLink: try XCTUnwrap(URL(string: bad))), bad)
        }
    }
}
