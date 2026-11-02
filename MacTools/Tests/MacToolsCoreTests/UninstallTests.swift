import Foundation
import XCTest
@testable import MacToolsCore

@MainActor
final class UninstallTests: XCTestCase {
    private let enabled = Data(#"{"launchAtLogin":true}"#.utf8)
    private let disabled = Data(#"{"launchAtLogin":false}"#.utf8)

    func testUnregistersAndConfirmsBeforeRemoval() async throws {
        var calls: [String] = []
        var current = enabled
        try await AppManager.unregisterAndUninstall(.dockPeek, readSettings: {
            calls.append("read")
            return current
        }, writeSettings: { patch in
            XCTAssertEqual(patch, Data(#"{"launchAtLogin":false}"#.utf8))
            calls.append("disable")
            current = self.disabled
            return current
        }, remove: { calls.append("remove") })
        XCTAssertEqual(calls, ["read", "disable", "read", "remove"])
    }

    func testDisabledRegistrationNeedsNoWrite() async throws {
        var removed = false
        try await AppManager.unregisterAndUninstall(.scrollSplit, readSettings: { self.disabled },
            writeSettings: { _ in XCTFail("Already disabled"); return self.disabled },
            remove: { removed = true })
        XCTAssertTrue(removed)
    }

    func testReadFailureDoesNotRemove() async {
        var removed = false
        do {
            try await AppManager.unregisterAndUninstall(.screenWren, readSettings: {
                throw AppManagerError.message("Settings unavailable.")
            }, writeSettings: { _ in XCTFail("No state was read"); return self.disabled },
               remove: { removed = true })
            XCTFail("Read failure must surface")
        } catch { XCTAssertFalse(removed) }
    }

    func testUnconfirmedDisableDoesNotRemove() async {
        for response in [enabled, Data(#"{"launchAtLogin":0}"#.utf8), disabled] {
            var removed = false
            do {
                try await AppManager.unregisterAndUninstall(.dockPeek, readSettings: { self.enabled },
                    writeSettings: { _ in response }, remove: { removed = true })
                XCTFail("Enabled, invalid, or stale state must prevent removal")
            } catch { XCTAssertFalse(removed) }
        }
    }

    func testStandaloneAppsNeverCallSettingsBridge() async throws {
        for app in [ManagedApp.latent, .sift] {
            var removed = false
            try await AppManager.unregisterAndUninstall(app, readSettings: {
                XCTFail("Unsupported settings bridge"); return self.enabled
            }, writeSettings: { _ in XCTFail("Unsupported settings bridge"); return self.disabled },
               remove: { removed = true })
            XCTAssertTrue(removed)
        }
    }
}
