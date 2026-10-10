import Foundation
import XCTest
@testable import MacTools

final class ToolSettingsSnapshotTests: XCTestCase {
    func testExistingBridgeSnapshotsRemainCompatible() throws {
        for app in ["dockPeek", "screenWren"] {
            let data = Data("{\"schemaVersion\":1,\"app\":\"\(app)\",\"launchAtLogin\":false,\"loginStatus\":\"notRegistered\"}".utf8)
            let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: data)
            XCTAssertEqual(snapshot.app, app)
            XCTAssertNil(snapshot.rules)
            XCTAssertNil(snapshot.permissions)
        }
    }

    func testScrollPermissionsDoNotInventRuntimeState() throws {
        let data = Data(#"{"schemaVersion":1,"app":"scrollSplit","launchAtLogin":true,"loginStatus":"enabled","enabled":true,"reverseVertical":true,"reverseHorizontal":false,"speedMultiplier":1.25,"permissions":{"accessibility":false,"inputMonitoring":false}}"#.utf8)
        let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.enabled, true)
        XCTAssertEqual(snapshot.speedMultiplier, 1.25)
        XCTAssertEqual(snapshot.permissions?["accessibility"], false)
        XCTAssertNil(snapshot.permissions?["eventTapActive"])
    }

    func testBrowserRuleAndProfileBridgeRoundTrip() throws {
        let data = Data(#"{"schemaVersion":1,"app":"linkRoutes","launchAtLogin":false,"loginStatus":"notRegistered","defaultBrowserIdentifier":"com.apple.Safari","isDefaultBrowser":true,"availableBrowsers":[{"identifier":"com.google.Chrome","name":"Google Chrome","profiles":[{"directory":"Profile 1","name":"Work"}]}],"rules":[{"id":"CBE5536C-BB6A-4AB3-B395-242A49AF16DB","domain":"example.com","includeSubdomains":true,"browserIdentifier":"com.google.Chrome","profileDirectory":"Profile 1"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.availableBrowsers?.first?.profiles.first?.name, "Work")
        let rules = try XCTUnwrap(snapshot.rules)
        let encoded = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode([BrowserRouteRule].self, from: encoded), rules)
        XCTAssertEqual(rules.first?.profileDirectory, "Profile 1")
    }
    @MainActor
    func testRuleDraftSurvivesRecreatingSettingsViewAndSnapshotRefresh() {
        let library = LibraryModel()
        let original = BrowserRouteRule(domain: "example.com", browserIdentifier: "com.apple.Safari")
        let firstView = ToolSettingsView(library: library)
        firstView.settings.synchronizeRouteDraft([original])
        firstView.settings.routeRules[0].domain = "work.example.com"

        // Sidebar navigation destroys and recreates this view, but retains LibraryModel.
        let recreatedView = ToolSettingsView(library: library)
        XCTAssertTrue(recreatedView.settings === firstView.settings)
        recreatedView.settings.synchronizeRouteDraft([original])
        XCTAssertEqual(recreatedView.settings.routeRules[0].domain, "work.example.com")
        XCTAssertTrue(recreatedView.settings.hasUnsavedRoutes)
        recreatedView.settings.discardRouteChanges()
        XCTAssertEqual(recreatedView.settings.routeRules, [original])
        XCTAssertFalse(recreatedView.settings.hasUnsavedRoutes)
    }

    @MainActor
    func testAcceptedRuleSaveReplacesDraftAndBaseline() {
        let model = ToolSettingsModel()
        let original = BrowserRouteRule(domain: "example.com", browserIdentifier: "com.apple.Safari")
        model.synchronizeRouteDraft([original])
        model.routeRules[0].domain = "work.example.com"
        let saved = model.routeRules
        model.acceptSavedRoutes(saved)
        XCTAssertFalse(model.hasUnsavedRoutes)
        model.routeRules.removeAll()
        model.discardRouteChanges()
        XCTAssertEqual(model.routeRules, saved)
    }

    func testScrollPermissionProvenanceGatesRunningAppClaims() throws {
        for source in ["currentProcess", "runningApp", "unknown"] {
            let json: [String: Any] = [
                "schemaVersion": 1, "app": "scrollSplit", "launchAtLogin": false,
                "loginStatus": "notRegistered", "permissionsSource": source,
                "eventTapStatus": "unknown", "permissions": ["accessibility": true, "inputMonitoring": true, "eventTapActive": true]
            ]
            let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(snapshot.hasLiveScrollPermissions, source == "runningApp")
            XCTAssertEqual(snapshot.liveEventTapActive, source == "runningApp" ? true : nil)
            if source == "currentProcess" { XCTAssertTrue(snapshot.scrollPermissionContext.contains("diagnostic process")) }
            if source == "unknown" { XCTAssertTrue(snapshot.scrollPermissionContext.contains("unavailable")) }
        }
    }

}
