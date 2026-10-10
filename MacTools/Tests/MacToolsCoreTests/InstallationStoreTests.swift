import Foundation
import XCTest
@testable import MacToolsCore

final class InstallationStoreTests: XCTestCase {
    private var root: URL!
    private var store: InstallationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = InstallationStore(payloadDirectory: root.appendingPathComponent("Payload"), userDirectory: root.appendingPathComponent("UserApps"), systemDirectory: root.appendingPathComponent("SystemApps"))
        store.osVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        store.verifySignature = { _, _ in }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func fixture(in directory: URL, app: ManagedApp = .dockPeek, release: String = "1.0", build: String = "1", content: String = "original", identifier: String? = nil, filename: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(filename ?? app.payloadFilename)
        let executableDirectory = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent(app.name)
        try Data(content.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let metadata: [String: Any] = ["CFBundleIdentifier": identifier ?? app.bundleIdentifier, "CFBundlePackageType": "APPL", "CFBundleExecutable": app.name, "CFBundleShortVersionString": release, "CFBundleVersion": build, "LSMinimumSystemVersion": "\(app.minimumOSMajor).0"]
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testInstallToRequestedScope() throws {
        let source = try fixture(in: store.payloadDirectory!)
        try store.install(.dockPeek, scope: .user)
        let installed = try XCTUnwrap(store.existing(.dockPeek))
        XCTAssertEqual(installed.path, store.userDirectory.appendingPathComponent("DockPeek.app").path)
        XCTAssertEqual(try store.fingerprint(source), try store.fingerprint(installed))
    }

    func testUpdateUsesExistingSystemPathDespiteUserScope() throws {
        try fixture(in: store.systemDirectory)
        try fixture(in: store.payloadDirectory!, release: "1.1", content: "new")
        try store.install(.dockPeek, scope: .user)
        let installed = try XCTUnwrap(store.existing(.dockPeek))
        XCTAssertEqual(installed.path, store.systemDirectory.appendingPathComponent("DockPeek.app").path)
        XCTAssertEqual(try store.metadata(installed, app: .dockPeek).version.release, "1.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.userDirectory.appendingPathComponent("DockPeek.app").path))
    }

    func testRenamedInstallationIsUpdatedInPlace() throws {
        let installed = try fixture(in: store.userDirectory, filename: "Dock Peek Local.app")
        try fixture(in: store.payloadDirectory!, release: "1.2")
        try store.install(.dockPeek, scope: .system)
        XCTAssertEqual(try store.existing(.dockPeek)?.path, installed.path)
        XCTAssertEqual(try store.metadata(installed, app: .dockPeek).version.release, "1.2")
    }

    func testWrongIdentityIsNeverReplaced() throws {
        let conflict = try fixture(in: store.userDirectory, identifier: "other.app")
        try fixture(in: store.payloadDirectory!)
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.path))
    }

    func testWrongPayloadIsRejected() throws {
        try fixture(in: store.payloadDirectory!, identifier: "other.app")
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertNil(try store.existing(.dockPeek))
    }

    func testDuplicateInstallationsAreRejected() throws {
        try fixture(in: store.userDirectory)
        try fixture(in: store.systemDirectory)
        XCTAssertThrowsError(try store.existing(.dockPeek))
    }

    func testDowngradeDoesNotTouchExistingBundle() throws {
        let old = try fixture(in: store.userDirectory, release: "1.10")
        let hash = try store.fingerprint(old)
        try fixture(in: store.payloadDirectory!, release: "1.9")
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertEqual(try store.fingerprint(old), hash)
    }

    func testLowerBuildDoesNotDowngrade() throws {
        try fixture(in: store.userDirectory, build: "10")
        try fixture(in: store.payloadDirectory!, build: "9")
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
    }

    func testSameVersionLocalRebuildChangesFingerprint() throws {
        let old = try fixture(in: store.userDirectory)
        let fresh = try fixture(in: store.payloadDirectory!, content: "rebuilt")
        XCTAssertNotEqual(try store.fingerprint(old), try store.fingerprint(fresh))
        try store.install(.dockPeek, scope: .user)
        XCTAssertEqual(try store.fingerprint(old), try store.fingerprint(fresh))
    }

    func testIdenticalContentHasIdenticalFingerprint() throws {
        let old = try fixture(in: store.userDirectory)
        let fresh = try fixture(in: store.payloadDirectory!)
        XCTAssertEqual(try store.fingerprint(old), try store.fingerprint(fresh))
    }

    func testCopyFailurePreservesExistingBundleAndCleansStaging() throws {
        let old = try fixture(in: store.userDirectory)
        let hash = try store.fingerprint(old)
        try fixture(in: store.payloadDirectory!, content: "new")
        store.copy = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            throw AppManagerError.message("Injected copy failure")
        }
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertEqual(try store.fingerprint(old), hash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.userDirectory.path), ["DockPeek.app"])
    }

    func testPostPlacementVerificationFailureRollsBack() throws {
        let old = try fixture(in: store.userDirectory)
        let hash = try store.fingerprint(old)
        try fixture(in: store.payloadDirectory!, content: "new")
        let target = old
        store.verifySignature = { url, _ in
            if url == target { throw AppManagerError.message("Injected final verification failure") }
        }
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertEqual(try store.fingerprint(old), hash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.userDirectory.path), ["DockPeek.app"])
    }

    func testNewInstallVerificationFailureLeavesNoInstall() throws {
        try fixture(in: store.payloadDirectory!)
        let target = store.userDirectory.appendingPathComponent("DockPeek.app")
        store.verifySignature = { url, _ in
            if url == target { throw AppManagerError.message("Injected final verification failure") }
        }
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertNil(try store.existing(.dockPeek))
    }

    func testBundleSymlinkIsRefused() throws {
        let source = try fixture(in: store.payloadDirectory!)
        try FileManager.default.createDirectory(at: store.userDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.userDirectory.appendingPathComponent("DockPeek.app"), withDestinationURL: source)
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertThrowsError(try store.uninstall(.dockPeek))
    }

    func testExecutableSymlinkIsRefused() throws {
        let source = try fixture(in: store.payloadDirectory!)
        let executable = source.appendingPathComponent("Contents/MacOS/DockPeek")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
    }

    func testExternalResourceSymlinkIsRefused() throws {
        let source = try fixture(in: store.payloadDirectory!)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Contents/External"), withDestinationURL: root)
        XCTAssertThrowsError(try store.install(.dockPeek, scope: .user))
        XCTAssertNil(try store.existing(.dockPeek))
    }

    func testUninstallMovesToInjectedTrashAndPreservesData() throws {
        let installed = try fixture(in: store.userDirectory)
        let hash = try store.fingerprint(installed)
        let destination = root.appendingPathComponent("Trash/DockPeek.app")
        store.trash = { url in
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
        }
        try store.uninstall(.dockPeek)
        XCTAssertNil(try store.existing(.dockPeek))
        XCTAssertEqual(try store.fingerprint(destination), hash)
    }

    func testUninstallWithoutInstallationFails() {
        XCTAssertThrowsError(try store.uninstall(.dockPeek))
    }

    func testUnsupportedOSIsRejectedBeforeCopy() throws {
        try fixture(in: store.payloadDirectory!, app: .screenWren)
        store.osVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertThrowsError(try store.install(.screenWren, scope: .user))
        XCTAssertNil(try store.existing(.screenWren))
    }

    private func settingsFixture(script: String, capability: Int? = 1) throws -> URL {
        let installed = try fixture(in: store.userDirectory, content: "#!/bin/sh\n" + script)
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["MacToolsSettingsProtocolVersion"] = capability
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        return installed
    }

    func testSettingsReadUsesExpectedCommandAndValidatesJSON() throws {
        try settingsFixture(script: """
        test "$1" = "--mac-tools-settings" && test "$2" = "read" || exit 8
        printf '%s' '{"schemaVersion":1,"app":"dockPeek","settings":{"enabled":true}}'
        """)
        let result = try store.settings(.dockPeek)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "dockPeek")
    }

    func testSettingsWriteTransportsExactJSONOnStdin() throws {
        try settingsFixture(script: """
        test "$1" = "--mac-tools-settings" && test "$2" = "write" || exit 8
        /bin/cat
        """)
        let patch = Data(#"{"schemaVersion":1,"app":"dockPeek","settings":{"enabled":false}}"#.utf8)
        XCTAssertEqual(try store.settings(.dockPeek, patch: patch), patch)
    }

    func testSettingsNonzeroExitSurfacesDiagnostics() throws {
        try settingsFixture(script: "printf '%s' 'The shortcut conflicts with another action.' >&2\nexit 9")
        XCTAssertThrowsError(try store.settings(.dockPeek)) { error in
            XCTAssertTrue(error.localizedDescription.contains("shortcut conflicts"))
        }
    }

    func testSettingsInvalidResponseRejected() throws {
        try settingsFixture(script: "printf '%s' '{\"schemaVersion\":1,\"app\":\"screenWren\"}'")
        XCTAssertThrowsError(try store.settings(.dockPeek))
    }

    func testOldAppDoesNotRunUnknownCommand() throws {
        let marker = root.appendingPathComponent("unexpected-launch")
        try settingsFixture(script: "touch '\(marker.path)'", capability: nil)
        XCTAssertThrowsError(try store.settings(.dockPeek))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSettingsRejectsInvalidPatchBeforeRunning() throws {
        let marker = root.appendingPathComponent("unexpected-write")
        try settingsFixture(script: "touch '\(marker.path)'")
        XCTAssertThrowsError(try store.settings(.dockPeek, patch: Data("not json".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSettingsLargeDiagnosticsDoNotDeadlock() throws {
        try settingsFixture(script: "/usr/bin/head -c 100000 /dev/zero >&2\nprintf '%s' '{\"schemaVersion\":1,\"app\":\"dockPeek\"}'")
        XCTAssertFalse(try store.settings(.dockPeek).isEmpty)
    }

    func testSettingsTimeoutReturnsError() throws {
        try settingsFixture(script: "exec /bin/sleep 5")
        store.settingsTimeout = 0.05
        XCTAssertThrowsError(try store.settings(.dockPeek)) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not respond"))
        }
    }

    @MainActor
    func testFailedUpdateReopensPreviousRunningAppAfterRollback() async throws {
        var actions: [String] = []
        do {
            try await AppManager.replaceAndRestoreRunningState(.dockPeek, wasRunning: true, replace: {
                actions.append("rollback")
                throw AppManagerError.message("Injected installation failure")
            }, reopen: { actions.append("reopen") })
            XCTFail("Expected the installation error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Injected installation failure")
        }
        XCTAssertEqual(actions, ["rollback", "reopen"])
    }

    @MainActor
    func testSuccessfulUpdateReopensPreviouslyRunningApp() async throws {
        var actions: [String] = []
        try await AppManager.replaceAndRestoreRunningState(.dockPeek, wasRunning: true, replace: {
            actions.append("install")
        }, reopen: { actions.append("reopen") })
        XCTAssertEqual(actions, ["install", "reopen"])
    }

    @MainActor
    func testFailedUpdateDoesNotStartPreviouslyStoppedApp() async throws {
        var reopened = false
        do {
            try await AppManager.replaceAndRestoreRunningState(.dockPeek, wasRunning: false, replace: {
                throw AppManagerError.message("Injected installation failure")
            }, reopen: { reopened = true })
            XCTFail("Expected the installation error")
        } catch { XCTAssertEqual(error.localizedDescription, "Injected installation failure") }
        XCTAssertFalse(reopened)
    }

    @MainActor
    func testRollbackReopenFailureRetainsBothErrors() async throws {
        do {
            try await AppManager.replaceAndRestoreRunningState(.dockPeek, wasRunning: true, replace: {
                throw AppManagerError.message("Injected installation failure")
            }, reopen: { throw AppManagerError.message("Injected reopen failure") })
            XCTFail("Expected the installation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Injected installation failure"))
            XCTAssertTrue(error.localizedDescription.contains("Injected reopen failure"))
        }
    }
}
