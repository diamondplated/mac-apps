import AppKit
import MacToolsCore
import SwiftUI
import XCTest
@testable import MacTools

/// Renders a settings page from a fixture so its layout can be looked at without an
/// installed app. Set MACTOOLS_SETTINGS_SNAPSHOT=/dir to write <app>-<appearance>.png there.
@MainActor
final class SettingsPageSnapshotTests: XCTestCase {
    private func render(_ app: ManagedApp, _ values: [String: Any], appearance: NSAppearance.Name, to directory: String?) throws {
        var json: [String: Any] = ["schemaVersion": 1, "app": app.rawValue, "launchAtLogin": true, "loginStatus": "enabled"]
        json.merge(values) { _, new in new }
        let library = LibraryModel()
        library.settingsApp = app
        library.toolSettings.snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let page = Form { ToolSettingsView(library: library, app: app) }.formStyle(.grouped).frame(width: 720, height: 1100)
        let host = NSHostingView(rootView: page)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        guard let directory else { return }
        let name = "\(app.rawValue)-\(appearance == .darkAqua ? "dark" : "light").png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    func testPagesWithTheNewOptionsLayOut() throws {
        let directory = ProcessInfo.processInfo.environment["MACTOOLS_SETTINGS_SNAPSHOT"]
        let dockPeek: [String: Any] = ["previewsEnabled": true, "showsTabs": true, "dismissalDelay": 0.6, "switcherEnabled": true,
                                       "dockClickHidesFrontApp": false, "dockScrollCyclesWindows": true, "dockMiddleClickOpensWindow": false,
                                       "restoresWindowLayouts": true,
                                       "permissions": ["accessibility": true, "screenRecording": false], "permissionsSource": "runningApp"]
        let browsers: [[String: Any]] = [["identifier": "com.google.Chrome", "name": "Google Chrome",
                                          "profiles": [["directory": "Profile 1", "name": "Work"], ["directory": "Default", "name": "Personal"]]],
                                         ["identifier": "com.apple.Safari", "name": "Safari", "profiles": []]]
        let rules: [[String: Any]] = [
            ["id": "1", "domain": "*", "includeSubdomains": true, "browserIdentifier": "com.google.Chrome", "profileDirectory": "Profile 1",
             "sourceBundleIdentifier": "com.apple.finder"],
            ["id": "2", "domain": "github.com", "includeSubdomains": true, "browserIdentifier": "com.google.Chrome", "profileDirectory": "Default"],
            ["id": "3", "domain": "apple.com", "includeSubdomains": true, "browserIdentifier": "com.apple.Safari"],
        ]
        let linkRoutes: [String: Any] = ["defaultBrowserIdentifier": "com.apple.Safari", "isDefaultBrowser": true, "availableBrowsers": browsers,
                                         "rules": rules, "stripsTrackingParameters": true, "unwrapsRedirects": false,
                                         "fileRules": [["id": "f1", "fileExtension": "md", "folder": "~/Notes/Work", "applicationIdentifier": "com.apple.TextEdit"],
                                                       ["id": "f2", "fileExtension": "csv", "applicationIdentifier": "com.apple.Numbers"]],
                                         "takenOverExtensions": ["md", "csv"]]
        let scrollSplit: [String: Any] = ["enabled": true, "reverseVertical": true, "reverseHorizontal": false, "speedMultiplier": 1.5,
                                          "smoothScrolling": true, "sideButtonsNavigate": true, "mouseAccelerationOff": false,
                                          "mouseAccelerationAvailable": true,
                                          "holdToQuit": true, "capsLockIsHyper": true, "capsLockTapIsEscape": false, "capsLockRemapAvailable": true,
                                          "cutAndPasteFilesInFinder": false,
                                          "shortcuts": [["command": "pastePlainText", "title": "Paste as Plain Text",
                                                         "shortcut": ["keyCode": 9, "carbonModifiers": 4352, "keyEquivalent": "v", "keyLabel": "V"]],
                                                        ["command": "toggleMicrophoneMute", "title": "Mute or Unmute Microphone", "shortcut": NSNull()]],
                                          "permissions": ["accessibility": true, "inputMonitoring": true, "eventTapActive": true],
                                          "permissionsSource": "runningApp"]
        let stayLit: [String: Any] = ["keepAwake": false, "keepAwakeApps": ["com.apple.finder"], "keepsDisplayAwake": false,
                                      "brightnessKeysControlDisplays": true, "volumeKeysControlDisplays": false,
                                      "awakeReason": "Awake while Finder is running",
                                      "externalDisplays": [["name": "Studio Monitor", "controllable": true], ["name": "Old Projector", "controllable": false]],
                                      "permissions": ["accessibility": true], "permissionsSource": "runningApp"]
        let mixBar: [String: Any] = ["remembersVolumes": true, "audioControlAvailable": true, "audioCaptureStatus": "denied",
                                     "appVolumes": [["bundleIdentifier": "com.apple.Music", "name": "Music", "volume": 0.4, "muted": false, "outputDeviceUID": NSNull()],
                                                    ["bundleIdentifier": "us.zoom.xos", "name": "Zoom", "volume": 1.5, "muted": false, "outputDeviceUID": "Headphones"],
                                                    ["bundleIdentifier": "com.apple.Safari", "name": "Safari", "volume": 1.0, "muted": true, "outputDeviceUID": NSNull()]]]
        let rightHere: [String: Any] = ["loginStatus": "notApplicable", "launchAtLogin": false,
                                        "showsNewFile": true, "showsOpenTerminal": true, "showsCopyPath": false,
                                        "newFileExtensions": ["txt", "md", "py"], "terminalBundleIdentifier": "com.apple.Terminal",
                                        "availableTerminals": [["bundleIdentifier": "com.apple.Terminal", "name": "Terminal"],
                                                               ["bundleIdentifier": "com.mitchellh.ghostty", "name": "Ghostty"]],
                                        "extensionEnabled": false]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(.mixBar, mixBar, appearance: appearance, to: directory)
            try render(.rightHere, rightHere, appearance: appearance, to: directory)
            try render(.stayLit, stayLit, appearance: appearance, to: directory)
            try render(.scrollSplit, scrollSplit, appearance: appearance, to: directory)
            try render(.dockPeek, dockPeek, appearance: appearance, to: directory)
            try render(.linkRoutes, linkRoutes, appearance: appearance, to: directory)
        }
    }
}
