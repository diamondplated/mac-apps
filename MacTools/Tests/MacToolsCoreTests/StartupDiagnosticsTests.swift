import Foundation
import XCTest
@testable import MacToolsCore

final class StartupDiagnosticsTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/Library/LaunchAgents/example.plist")
    private func data(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    func testProgramTakesPrecedenceOverArgumentsAndAttributionUsesOuterApp() throws {
        let result = try StartupDiagnostics.parse(data: data([
            "Label": "example.agent", "Program": "/Applications/Example App.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/helper",
            "ProgramArguments": ["/wrong/executable"], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false]
        ]), fileURL: file, origin: "Test", exists: { $0.contains("Example App") })
        XCTAssertEqual(result.displayName, "Example App")
        XCTAssertEqual(result.appURL?.path, "/Applications/Example App.app")
        XCTAssertEqual(result.targetStatus, .present)
        XCTAssertTrue(result.runAtLoad)
        XCTAssertTrue(result.keepsAlive)
    }

    func testMissingAbsoluteTargetAndDisabledDeclaration() throws {
        let result = try StartupDiagnostics.parse(data: data([
            "Label": "example.gone", "ProgramArguments": ["/Volumes/Offline/Helper", "--start"], "Disabled": true
        ]), fileURL: file, origin: "Test", exists: { _ in false })
        XCTAssertEqual(result.targetStatus, .missing)
        XCTAssertTrue(result.declaredDisabled)
        XCTAssertNil(result.appURL)
        XCTAssertEqual(result.executable, "/Volumes/Offline/Helper")
    }

    func testRelativeProgramAndMissingProgramRemainUnknown() throws {
        for dictionary: [String: Any] in [
            ["Label": "relative", "ProgramArguments": ["helper"]],
            ["Label": "no-program"],
            ["Label": "empty-arguments", "ProgramArguments": []]
        ] {
            let result = try StartupDiagnostics.parse(data: data(dictionary), fileURL: file, origin: "Test", exists: { _ in false })
            XCTAssertEqual(result.targetStatus, .unresolved)
        }
    }

    func testMalformedAndUnlabelledDefinitionsAreRejected() throws {
        XCTAssertThrowsError(try StartupDiagnostics.parse(data: Data("not a plist".utf8), fileURL: file, origin: "Test"))
        XCTAssertThrowsError(try StartupDiagnostics.parse(data: data(["Program": "/bin/true"]), fileURL: file, origin: "Test"))
        XCTAssertThrowsError(try StartupDiagnostics.parse(data: data(["Label": ""]), fileURL: file, origin: "Test"))
    }

    func testInventoryContinuesAfterUnreadableDefinitionAndIgnoresNonPlists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data(["Label": "valid", "Program": "/bin/true"]).write(to: directory.appendingPathComponent("valid.plist"))
        try Data("bad".utf8).write(to: directory.appendingPathComponent("broken.plist"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let result = StartupDiagnostics.inventory(directories: [(directory, "Fixture")])
        XCTAssertEqual(result.entries.map(\.label), ["valid"])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("broken.plist"))
    }

    func testAppAttributionRequiresAbsoluteAppAncestor() {
        XCTAssertNil(StartupDiagnostics.applicationURL(forExecutable: "Example.app/helper"))
        XCTAssertNil(StartupDiagnostics.applicationURL(forExecutable: "/Library/Helpers/example"))
        XCTAssertEqual(StartupDiagnostics.applicationURL(forExecutable: "/Applications/A.app/Contents/MacOS/A")?.path, "/Applications/A.app")
    }
}
