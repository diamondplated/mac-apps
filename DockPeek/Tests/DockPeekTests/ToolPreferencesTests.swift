import XCTest
import ServiceManagement
@testable import DockPeek

final class ToolPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var preferences: ToolPreferences!

    override func setUp() {
        suite = "DockPeekTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = ToolPreferences(defaults: defaults, permissionState: { ["accessibility": true, "screenRecording": false] })
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
    private func patch(_ json: String) throws -> DockPeekSettingsPatch {
        try DockPeekSettingsPatch(data: Data(json.utf8))
    }
    func testDefaultsAndActualLoginStatus() {
        let snapshot = preferences.snapshot(loginStatus: .requiresApproval)
        XCTAssertTrue(snapshot.previewsEnabled)
        XCTAssertTrue(snapshot.showsTabs)
        XCTAssertEqual(snapshot.dismissalDelay, 0.6)
        XCTAssertFalse(snapshot.launchAtLogin)
        XCTAssertEqual(snapshot.loginStatus, "requiresApproval")
        XCTAssertTrue(preferences.snapshot(loginStatus: .enabled).launchAtLogin)
    }
    func testBehaviorPreferencesPersistWithoutSavingLoginState() throws {
        var requestedLogin: Bool?
        try preferences.apply(patch("""
            {"launchAtLogin":true,"previewsEnabled":false,"showsTabs":false,"dismissalDelay":1.25}
            """)) { requestedLogin = $0 }
        let reloaded = ToolPreferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(reloaded.previewsEnabled)
        XCTAssertFalse(reloaded.showsTabs)
        XCTAssertEqual(reloaded.dismissalDelay, 1.25)
        XCTAssertEqual(requestedLogin, true)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))
    }
    func testSnapshotIncludesReadOnlyOwnProcessPermissionEvidence() throws {
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let data = try JSONEncoder().encode(preferences.snapshot(loginStatus: .notRegistered))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(json["permissions"] as? [String: Bool])
        XCTAssertEqual(permissions, ["accessibility": true, "screenRecording": false])
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertThrowsError(try patch(#"{"permissions":{"screenRecording":true}}"#))
    }
    func testMalformedPatchesDoNotPartiallyApply() {
        let invalid = [
            "{\"previewsEnabled\":false,\"dismissalDelay\":0.09}",
            "{\"previewsEnabled\":false,\"dismissalDelay\":3.1}",
            "{\"previewsEnabled\":false,\"dismissalDelay\":true}",
            "{\"previewsEnabled\":false,\"showsTabs\":1}",
            "{\"previewsEnabled\":false,\"showsTabs\":null}",
            "{\"previewsEnabled\":false,\"launchAtLogin\":\"yes\"}",
            "{\"previewsEnabled\":false,\"schemaVersion\":1}",
            "{\"previewsEnabled\":false,\"unknown\":true}", "[]", "{"
        ]
        for json in invalid {
            var loginChanged = false
            XCTAssertThrowsError(try preferences.apply(patch(json)) { _ in loginChanged = true }, json)
            XCTAssertFalse(loginChanged)
            XCTAssertTrue(preferences.previewsEnabled)
            XCTAssertTrue(preferences.showsTabs)
            XCTAssertNil(defaults.object(forKey: "previewsEnabled"))
        }
    }
    func testLoginFailureLeavesBehaviorPreferencesUnchanged() throws {
        enum Failure: Error { case refused }
        XCTAssertThrowsError(try preferences.apply(patch("""
            {"launchAtLogin":true,"previewsEnabled":false,"dismissalDelay":2}
            """)) { _ in throw Failure.refused })
        XCTAssertTrue(preferences.previewsEnabled)
        XCTAssertEqual(preferences.dismissalDelay, 0.6)
    }
    func testDelayBoundariesAndCustomDismissalTiming() throws {
        for delay in [0.1, 3.0] {
            try preferences.apply(patch("{\"dismissalDelay\":\(delay)}")) { _ in XCTFail() }
            XCTAssertEqual(preferences.dismissalDelay, delay)
        }
        var state = HoverDismissalState(gracePeriod: 1.5)
        let point = CGPoint(x: 10, y: 10)
        XCTAssertFalse(state.shouldDismiss(pointer: point, dockFrame: nil, previewFrame: nil, now: 0))
        XCTAssertFalse(state.shouldDismiss(pointer: point, dockFrame: nil, previewFrame: nil, now: 1.4))
        XCTAssertTrue(state.shouldDismiss(pointer: point, dockFrame: nil, previewFrame: nil, now: 1.6))
    }
}
