import Foundation
import XCTest
@testable import MacToolsCore

final class PermissionDiagnosticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionDoctorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func appBundle(_ name: String, identifier: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testFindsRenamedCopiesAndDuplicates() throws {
        try appBundle("DockPeek.app", identifier: ManagedApp.dockPeek.bundleIdentifier)
        try appBundle("DockPeek Old.app", identifier: ManagedApp.dockPeek.bundleIdentifier)
        let discovery = PermissionDiagnostics.discover(.dockPeek, directories: [root])
        XCTAssertEqual(discovery.candidates.count, 2)
        XCTAssertEqual(discovery.checks.first?.status, .attention)
        XCTAssertTrue(discovery.checks.first?.detail.contains("2 possible copies") == true)
    }

    func testExpectedFilenameWithWrongIdentityIsReported() throws {
        try appBundle("DockPeek.app", identifier: "other.app")
        let discovery = PermissionDiagnostics.discover(.dockPeek, directories: [root])
        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.checks.first?.status, .attention)
        XCTAssertEqual(discovery.candidates.first?.identifier, "other.app")
    }

    func testSymbolicLinkIsReportedInsteadOfTreatedAsInstalledCopy() throws {
        let actual = try appBundle("Original.app", identifier: ManagedApp.dockPeek.bundleIdentifier)
        let search = root.appendingPathComponent("Search")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: search.appendingPathComponent("DockPeek.app"), withDestinationURL: actual)
        let discovery = PermissionDiagnostics.discover(.dockPeek, directories: [search])
        XCTAssertEqual(discovery.candidates.first?.isSymbolicLink, true)
        XCTAssertEqual(discovery.checks.first?.status, .attention)
    }

    func testNoInstallIsNotReportedAsHealthy() {
        let discovery = PermissionDiagnostics.discover(.dockPeek, directories: [root])
        XCTAssertTrue(discovery.candidates.isEmpty)
        XCTAssertEqual(discovery.checks.first?.status, .attention)
    }

    func testRunningCopyFromBuildDirectoryIsFlagged() {
        let installed = URL(fileURLWithPath: "/Applications/DockPeek.app")
        let other = URL(fileURLWithPath: "/tmp/build/DockPeek.app")
        XCTAssertEqual(PermissionDiagnostics.runningFinding(installations: [installed], runningURLs: [other], runningCount: 1).status, .attention)
        XCTAssertEqual(PermissionDiagnostics.runningFinding(installations: [installed], runningURLs: [installed], runningCount: 1).status, .passed)
        XCTAssertEqual(PermissionDiagnostics.runningFinding(installations: [installed], runningURLs: [], runningCount: 1).status, .attention)
        XCTAssertEqual(PermissionDiagnostics.runningFinding(installations: [installed], runningURLs: [], runningCount: 0).status, .notChecked)
    }

    func testSettingsReadinessDoesNotImplyPermissions() {
        let data = Data(#"{"schemaVersion":1,"app":"dockPeek","previewsEnabled":true}"#.utf8)
        XCTAssertTrue(PermissionDiagnostics.validSnapshot(data, app: .dockPeek))
        let permissions = PermissionDiagnostics.permissionFindings(.dockPeek, snapshot: data)
        XCTAssertEqual(permissions.count, 2)
        XCTAssertTrue(permissions.allSatisfy { $0.status == .notChecked })
    }

    func testOnlyOwnVersionedBooleanPermissionEvidenceIsAccepted() {
        let data = Data(#"{"schemaVersion":1,"app":"dockPeek","permissions":{"accessibility":true,"screenRecording":false}}"#.utf8)
        let permissions = PermissionDiagnostics.permissionFindings(.dockPeek, snapshot: data)
        XCTAssertEqual(permissions.first { $0.id == "accessibility" }?.status, .passed)
        XCTAssertEqual(permissions.first { $0.id == "screenRecording" }?.status, .attention)
        XCTAssertTrue(PermissionDiagnostics.permissionFindings(.screenWren, snapshot: data).allSatisfy { $0.status == .notChecked })
        let wrongSchema = Data(#"{"schemaVersion":2,"app":"dockPeek","permissions":{"accessibility":true}}"#.utf8)
        XCTAssertTrue(PermissionDiagnostics.permissionFindings(.dockPeek, snapshot: wrongSchema).allSatisfy { $0.status == .notChecked })
    }

    func testNumericAndStringPermissionClaimsAreNotBooleans() {
        let data = Data(#"{"schemaVersion":1,"app":"dockPeek","permissions":{"accessibility":1,"screenRecording":"true"}}"#.utf8)
        XCTAssertTrue(PermissionDiagnostics.permissionFindings(.dockPeek, snapshot: data).allSatisfy { $0.status == .notChecked })
    }

    func testSignedIdentifierRequiresExactField() {
        XCTAssertEqual(PermissionDiagnostics.signedIdentifier("Executable=/Applications/DockPeek.app\nIdentifier=com.andrew.dockpeek\nTeamIdentifier=not set"), "com.andrew.dockpeek")
        XCTAssertNil(PermissionDiagnostics.signedIdentifier("TeamIdentifier=com.andrew.dockpeek"))
    }

    func testScrollSplitReportsOwnInputPermissionsWithoutInferringEventTapState() {
        let data = Data(#"{"schemaVersion":1,"app":"scrollSplit","permissions":{"accessibility":true,"inputMonitoring":false,"eventTapActive":false}}"#.utf8)
        let permissions = PermissionDiagnostics.permissionFindings(.scrollSplit, snapshot: data)
        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions.first { $0.id == "accessibility" }?.status, .passed)
        XCTAssertEqual(permissions.first { $0.id == "inputMonitoring" }?.status, .attention)
        XCTAssertFalse(permissions.contains { $0.id == "eventTapActive" })
    }

    func testLinkRoutesDefaultBrowserIsSeparateFromTCC() {
        let data = Data(#"{"schemaVersion":1,"app":"linkRoutes","isDefaultBrowser":false}"#.utf8)
        XCTAssertTrue(PermissionDiagnostics.permissionFindings(.linkRoutes, snapshot: data).isEmpty)
        XCTAssertEqual(PermissionDiagnostics.routingFinding(.linkRoutes, snapshot: data)?.status, .attention)
        XCTAssertNil(PermissionDiagnostics.routingFinding(.dockPeek, snapshot: data))
    }
}
