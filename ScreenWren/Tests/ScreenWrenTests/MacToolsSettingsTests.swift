import XCTest
import Carbon
@testable import ScreenWren

final class MacToolsSettingsTests: XCTestCase {
    @MainActor
    private func withBridge(_ body: (MacToolsSettingsBridge, UserDefaults, () -> Int) throws -> Void) rethrows {
        let name = "ScreenWren.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        var enabled = false
        let bridge = MacToolsSettingsBridge(defaults: defaults,
            loginState: { (enabled, enabled ? "On" : "Off") },
            setLoginEnabled: { enabled = $0; calls += 1 }, permissionState: { ["screenRecording": false] })
        try body(bridge, defaults, { calls })
    }

    @MainActor func testLoginWritesRequireDirectSystemOrUserApplicationsLocation() {
        let home = URL(fileURLWithPath: "/Users/ScreenWrenSettingsTest")
        for path in ["/Applications/ScreenWren.app", "/Applications/Renamed.app",
                     "/Users/ScreenWrenSettingsTest/Applications/ScreenWren.app"] {
            XCTAssertTrue(MacToolsSettingsBridge.isInstalledBundle(URL(fileURLWithPath: path), homeDirectory: home), path)
        }
        for path in ["/tmp/dist/ScreenWren.app", "/Applications/Mac Tools.app/Contents/Resources/ScreenWren.app",
                     "/Users/SomeoneElse/Applications/ScreenWren.app", "/Applications/ScreenWren"] {
            XCTAssertFalse(MacToolsSettingsBridge.isInstalledBundle(URL(fileURLWithPath: path), homeDirectory: home), path)
        }
    }

    @MainActor func testRoundTripUsesExistingPreferenceStoresAndActualLoginState() throws {
        try withBridge { bridge, defaults, calls in
            let snapshot = try bridge.write(Data(#"{"captureDestination":"review","showsThumbnail":true,"adjustBeforeCapture":true,"selectionWidth":800,"selectionHeight":600,"aspectRatio":1.5,"presets":[{"name":"Card","width":800,"height":600}],"launchAtLogin":true}"#.utf8))
            XCTAssertEqual(snapshot.schemaVersion, 1)
            XCTAssertEqual(snapshot.app, "screenWren")
            XCTAssertEqual(snapshot.selectionWidth, 800)
            XCTAssertEqual(snapshot.presets.first?.name, "Card")
            XCTAssertTrue(snapshot.launchAtLogin)
            XCTAssertEqual(snapshot.loginStatus, "On")
            XCTAssertEqual(calls(), 1)
            XCTAssertEqual(WorkflowPreferences(defaults: defaults).destination, .review)
            let decoded = try JSONDecoder().decode(MacToolsSettingsBridge.Snapshot.self,
                from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(decoded.shortcuts.count, ShortcutCommand.allCases.count)
            let reset = try bridge.write(Data(#"{"selectionWidth":0,"selectionHeight":0,"aspectRatio":0}"#.utf8))
            XCTAssertEqual(reset.selectionWidth, 0)
            XCTAssertEqual(reset.aspectRatio, 0)
        }
    }

    @MainActor func testMalformedPatchesDoNotPartiallyWriteOrInvokeLogin() throws {
        try withBridge { bridge, defaults, calls in
            let invalid = [
                #"{"captureDestination":"invalid"}"#,
                #"{"showsThumbnail":1}"#,
                #"{"showsThumbnail":null}"#,
                #"{"unknown":true}"#,
                #"{"permissions":{"screenRecording":true}}"#,
                #"{"selectionWidth":10}"#,
                #"{"selectionWidth":3,"selectionHeight":100}"#,
                #"{"aspectRatio":101}"#,
                #"{"presets":[{"name":"A","width":4,"height":4},{"name":"a","width":4,"height":4}]}"#,
                #"{"presets":[{"name":"A","width":4,"height":4,"extra":1}]}"#,
                #"{"shortcuts":[{"command":"unknown","title":"Bad","shortcut":null}]}"#,
                #"{"shortcuts":[{"command":"capture","title":"Capture","shortcut":{"keyCode":128,"carbonModifiers":256,"keyEquivalent":"p","keyLabel":"P"}}]}"#,
                #"{"shortcuts":[{"command":"capture","title":"Capture","shortcut":{"keyCode":1,"carbonModifiers":512,"keyEquivalent":"p","keyLabel":"P"}}]}"#,
                #"{"resetShortcuts":true,"shortcuts":[]}"#
            ]
            let before = defaults.dictionaryRepresentation() as NSDictionary
            for json in invalid {
                let patch = String(json.dropLast()) + #", "launchAtLogin":true, "adjustBeforeCapture":true}"#
                XCTAssertThrowsError(try bridge.write(Data(patch.utf8)), json)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before, json)
            }
            XCTAssertEqual(calls(), 0)
        }
    }

    @MainActor func testShortcutSubsetValidatesAgainstUnchangedCommandsAndCanReset() throws {
        try withBridge { bridge, defaults, _ in
            let collision = #"{"shortcuts":[{"command":"frontWindow","title":"Front","shortcut":{"keyCode":35,"carbonModifiers":4096,"keyEquivalent":"p","keyLabel":"P"}}]}"#
            XCTAssertThrowsError(try bridge.write(Data(collision.utf8)))
            let clear = #"{"shortcuts":[{"command":"capture","title":"Capture","shortcut":null}]}"#
            _ = try bridge.write(Data(clear.utf8))
            XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .capture))
            _ = try bridge.write(Data(collision.utf8))
            XCTAssertNotNil(ShortcutStore(defaults: defaults).shortcut(for: .frontWindow))
            let reset = try bridge.write(Data(#"{"resetShortcuts":true}"#.utf8))
            XCTAssertNotNil(reset.shortcuts.first { $0.command == .capture }?.shortcut)
            XCTAssertNil(reset.shortcuts.first { $0.command == .frontWindow }?.shortcut)
        }
    }

    @MainActor func testLoginFailureLeavesPreferencesUntouchedAndNotificationsTrackShortcutChanges() throws {
        let name = "ScreenWren.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var notifications: [Bool] = []
        let bridge = MacToolsSettingsBridge(defaults: defaults, loginState: { (false, "Off") },
            setLoginEnabled: { _ in throw MacToolsSettingsBridge.Failure(message: "Denied") },
            notify: { notifications.append($0) }, permissionState: { ["screenRecording": false] })
        XCTAssertThrowsError(try bridge.write(Data(#"{"showsThumbnail":true,"launchAtLogin":true}"#.utf8)))
        XCTAssertFalse(WorkflowPreferences(defaults: defaults).showsThumbnail)
        XCTAssertTrue(notifications.isEmpty)
        _ = try bridge.write(Data(#"{"showsThumbnail":true}"#.utf8))
        _ = try bridge.write(Data(#"{"resetShortcuts":true}"#.utf8))
        XCTAssertEqual(notifications, [false, true])
    }

    @MainActor func testSnapshotIncludesReadOnlyOwnProcessPermissionEvidence() throws {
        try withBridge { bridge, defaults, calls in
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let data = try JSONEncoder().encode(bridge.snapshot())
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["permissions"] as? [String: Bool], ["screenRecording": false])
            XCTAssertEqual(json["permissionsSource"] as? String, "currentProcess")
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            XCTAssertEqual(calls(), 0)
        }
    }

    @MainActor private func bridge(_ defaults: UserDefaults,
                                   running: @escaping () -> [String: Bool]?) -> MacToolsSettingsBridge {
        MacToolsSettingsBridge(defaults: defaults, loginState: { (false, "Off") }, setLoginEnabled: { _ in },
                               permissionState: { ["screenRecording": false] }, runningAppPermissions: running)
    }

    /// The manager runs this helper, so macOS can judge the helper's own permission by the
    /// manager. When the running app answers, its answer is the one that counts.
    @MainActor func testRunningAppPermissionReplacesTheHelpersOwnAnswer() throws {
        let name = "ScreenWren.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let live = bridge(defaults) { ["screenRecording": true, "unexpected": true] }.snapshot()
        XCTAssertEqual(live.permissions, ["screenRecording": true], "Only the known key is passed through")
        XCTAssertEqual(live.permissionsSource, "runningApp")

        let silent = bridge(defaults) { nil }.snapshot()
        XCTAssertEqual(silent.permissions, ["screenRecording": false])
        XCTAssertEqual(silent.permissionsSource, "currentProcess")

        let unusable = bridge(defaults) { ["somethingElse": true] }.snapshot()
        XCTAssertEqual(unusable.permissionsSource, "currentProcess", "A reply without the key is no answer")

        // The new fields are output only; a patch naming them is still rejected.
        XCTAssertThrowsError(try bridge(defaults) { nil }.write(Data(#"{"permissionsSource":"runningApp"}"#.utf8)))
    }

    @MainActor func testOnlyOneOtherCopyFromThisSameBundleIsAsked() {
        let own = URL(fileURLWithPath: "/Applications/ScreenWren.app")
        let ask = { (copies: [MacToolsSettingsBridge.RunningCopy]) in
            MacToolsSettingsBridge.runningCopyToAsk(copies, ownBundleURL: own, ownProcessIdentifier: 10)
        }
        XCTAssertNil(ask([]), "Nothing running")
        XCTAssertEqual(ask([.init(processIdentifier: 20, bundleURL: own)]), 20)
        XCTAssertEqual(ask([.init(processIdentifier: 20, bundleURL: URL(fileURLWithPath: "/Applications/./ScreenWren.app"))]), 20)
        XCTAssertNil(ask([.init(processIdentifier: 10, bundleURL: own)]), "The helper never asks itself")
        XCTAssertNil(ask([.init(processIdentifier: 20, bundleURL: URL(fileURLWithPath: "/tmp/dist/ScreenWren.app"))]),
                     "A different copy's permission is not this copy's")
        XCTAssertNil(ask([.init(processIdentifier: 20, bundleURL: nil)]))
        XCTAssertNil(ask([.init(processIdentifier: 20, bundleURL: own), .init(processIdentifier: 30, bundleURL: own)]),
                     "Two copies is an ambiguous answer")
    }

    @MainActor func testStatusRequestRoundTripCarriesTheAnsweringProcess() {
        let center = DistributedNotificationCenter.default()
        let observer = MacToolsSettingsBridge.answerStatusRequests(center: center) { ["screenRecording": true] }
        defer { center.removeObserver(observer) }
        let own = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(MacToolsSettingsBridge.askRunningApp(processIdentifier: own, timeout: 3, center: center),
                       ["screenRecording": true])
        XCTAssertNil(MacToolsSettingsBridge.askRunningApp(processIdentifier: own + 1, timeout: 0.3, center: center),
                     "A reply from a different process is ignored")
    }

    @MainActor func testSettingsOpensTheManagerPageThenFallsBack() {
        var opened: [URL] = []
        var launched: [URL] = []
        var alerts = 0
        let manager = URL(fileURLWithPath: "/Applications/Mac Tools.app")
        func open(page: Bool, managerInstalled: Bool) -> SettingsOpenOutcome {
            openScreenWrenSettings(
                openURL: { opened.append($0); return page }, managerCandidates: [manager],
                managerExists: { _ in managerInstalled }, launchManager: { launched.append($0) },
                reportMissingManager: { alerts += 1 })
        }
        XCTAssertEqual(open(page: true, managerInstalled: true), .settingsPage)
        XCTAssertEqual(opened, [URL(string: "mactools://app/screenWren")!])
        XCTAssertEqual(launched, [])
        XCTAssertEqual(open(page: false, managerInstalled: true), .manager(manager), "An older manager is launched")
        XCTAssertEqual(launched, [manager])
        XCTAssertEqual(open(page: false, managerInstalled: false), .managerMissing)
        XCTAssertEqual(alerts, 1)
    }
}
