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
        let page = Form { ToolSettingsView(library: library, app: app) }.formStyle(.grouped).frame(width: 720, height: 760)
        let host = NSHostingView(rootView: page)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
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
                                         "rules": rules, "stripsTrackingParameters": true, "unwrapsRedirects": false]
        let scrollSplit: [String: Any] = ["enabled": true, "reverseVertical": true, "reverseHorizontal": false, "speedMultiplier": 1.5,
                                          "smoothScrolling": true, "sideButtonsNavigate": true, "mouseAccelerationOff": false,
                                          "mouseAccelerationAvailable": true,
                                          "permissions": ["accessibility": true, "inputMonitoring": true, "eventTapActive": true],
                                          "permissionsSource": "runningApp"]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(.scrollSplit, scrollSplit, appearance: appearance, to: directory)
            try render(.dockPeek, dockPeek, appearance: appearance, to: directory)
            try render(.linkRoutes, linkRoutes, appearance: appearance, to: directory)
        }
    }
}
