import Foundation
import XCTest
@testable import MacToolsCore

final class StorageDiagnosticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SpaceWatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ name: String, size: Int = 8_192) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Varied bytes prevent compression from making an allocation-growth test misleading.
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 256) }).write(to: url)
        return url
    }

    func testMeasuresFilesAndImmediateFolderTotals() throws {
        try file("one.dat")
        try file("Sub/two.dat", size: 32_768)
        let scan = try StorageDiagnostics.scan(root: root)
        XCTAssertEqual(scan.fileCount, 2)
        XCTAssertEqual(scan.logicalBytes, 40_960)
        XCTAssertEqual(Set(scan.folders.map(\.name)), ["Files in this folder", "Sub"])
        XCTAssertEqual(scan.folders.reduce(0) { $0 + $1.allocatedBytes }, scan.allocatedBytes)
        XCTAssertTrue(scan.isComplete)
    }

    func testBoundedScanCannotBecomeGrowthBaseline() throws {
        for n in 0..<20 { try file("\(n).dat") }
        let partial = try StorageDiagnostics.scan(root: root, limits: .init(maximumEntries: 3, maximumResults: 2))
        let complete = try StorageDiagnostics.scan(root: root)
        XCTAssertTrue(partial.wasLimited)
        XCTAssertLessThanOrEqual(partial.fileCount, 3)
        XCTAssertLessThanOrEqual(partial.largestFiles.count, 2)
        XCTAssertNil(complete.growth(since: partial))
    }

    func testSkipsSymlinksAndRejectsSymlinkRoot() throws {
        try file("real/data.dat")
        let link = root.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let scan = try StorageDiagnostics.scan(root: root)
        XCTAssertEqual(scan.fileCount, 1)
        XCTAssertEqual(scan.skippedCount, 1)
        XCTAssertThrowsError(try StorageDiagnostics.scan(root: link))
    }

    func testGrowthUsesActualSameFolderMeasurements() throws {
        try file("one.dat")
        let previous = try StorageDiagnostics.scan(root: root)
        try file("new.dat", size: 64_000)
        let current = try StorageDiagnostics.scan(root: root)
        XCTAssertEqual(current.growth(since: previous), current.allocatedBytes - previous.allocatedBytes)
        XCTAssertGreaterThan(try XCTUnwrap(current.growth(since: previous)), 0)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(try StorageDiagnostics.scan(root: other).growth(since: previous))
    }

    func testTrashRevalidatesIdentityAndRegularFileType() throws {
        let path = try file("data.dat")
        let scan = try StorageDiagnostics.scan(root: root)
        let candidate = try XCTUnwrap(scan.largestFiles.first)
        XCTAssertEqual(try StorageDiagnostics.validatedTrashURLs(files: [candidate], snapshot: scan).map { $0.standardizedFileURL }, [path.standardizedFileURL])
        try Data("replacement".utf8).write(to: path, options: .atomic)
        XCTAssertThrowsError(try StorageDiagnostics.validatedTrashURLs(files: [candidate], snapshot: scan))
    }

    func testTrashRejectsSymlinkReplacementAndOutsideCandidate() throws {
        let path = try file("data.dat")
        let scan = try StorageDiagnostics.scan(root: root)
        let candidate = try XCTUnwrap(scan.largestFiles.first)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try StorageDiagnostics.validatedTrashURLs(files: [candidate], snapshot: scan))
        let outside = StorageFile(relativePath: "../outside", allocatedBytes: 0, logicalBytes: 0, identity: candidate.identity)
        XCTAssertThrowsError(try StorageDiagnostics.validatedTrashURLs(files: [outside], snapshot: scan))
    }

    func testTrashRejectsLibraryFiles() throws {
        try file("Library/Preferences/setting.dat")
        let scan = try StorageDiagnostics.scan(root: root)
        XCTAssertThrowsError(try StorageDiagnostics.validatedTrashURLs(files: scan.largestFiles, snapshot: scan))
    }

    func testHardlinksAreNotCountedTwice() throws {
        let original = try file("one.dat")
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("two.dat"))
        let scan = try StorageDiagnostics.scan(root: root)
        XCTAssertEqual(scan.fileCount, 1)
        XCTAssertEqual(scan.skippedCount, 1)
    }

    func testSkipsApplicationPackageContents() throws {
        try file("Example.app/Contents/MacOS/Example")
        let scan = try StorageDiagnostics.scan(root: root)
        XCTAssertEqual(scan.fileCount, 0)
        XCTAssertEqual(scan.skippedCount, 1)
    }

    func testTrashRejectsReplacedParentDirectory() throws {
        try file("Sub/data.dat")
        let scan = try StorageDiagnostics.scan(root: root)
        let sub = root.appendingPathComponent("Sub")
        let moved = root.appendingPathComponent("Original")
        try FileManager.default.moveItem(at: sub, to: moved)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: moved)
        XCTAssertThrowsError(try StorageDiagnostics.validatedTrashURLs(files: scan.largestFiles, snapshot: scan))
    }

    func testCancellationStopsScan() async throws {
        let selectedRoot = try XCTUnwrap(root)
        let task = Task.detached { () throws -> StorageSnapshot in
            while !Task.isCancelled { await Task.yield() }
            return try StorageDiagnostics.scan(root: selectedRoot)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled scan returned a snapshot") }
        catch is CancellationError { }
    }
}
