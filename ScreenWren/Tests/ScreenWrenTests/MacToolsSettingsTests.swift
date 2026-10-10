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
            XCTAssertEqual(decoded.shortcuts.count, 7)
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
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            XCTAssertEqual(calls(), 0)
        }
    }
}
