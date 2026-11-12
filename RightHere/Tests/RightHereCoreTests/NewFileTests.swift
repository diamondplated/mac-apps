import XCTest
@testable import RightHereCore

final class NewFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RightHereTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore permissions a test removed, so the temporary folder can go.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }

    func testNamesCount() {
        XCTAssertEqual(NewFile.name(number: 1, ext: "txt"), "untitled.txt")
        XCTAssertEqual(NewFile.name(number: 2, ext: "txt"), "untitled 2.txt")
        XCTAssertEqual(NewFile.name(number: 3, ext: ""), "untitled 3")
    }

    func testCreatesEmptyFileThenNextFreeName() throws {
        let one = try NewFile.create(in: directory, ext: "txt")
        let two = try NewFile.create(in: directory, ext: "txt")
        XCTAssertEqual(one.lastPathComponent, "untitled.txt")
        XCTAssertEqual(two.lastPathComponent, "untitled 2.txt")
        XCTAssertEqual(try Data(contentsOf: one).count, 0)
        XCTAssertEqual(try names(), ["untitled 2.txt", "untitled.txt"])
    }

    func testNeverOverwritesAndFindsTheGapAfterTwoHundredFiles() throws {
        try Data("keep".utf8).write(to: directory.appendingPathComponent("untitled.txt"))
        for n in 2...200 { try Data("keep \(n)".utf8).write(to: directory.appendingPathComponent(NewFile.name(number: n, ext: "txt"))) }
        let created = try NewFile.create(in: directory, ext: "txt")
        XCTAssertEqual(created.lastPathComponent, "untitled 201.txt")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("untitled.txt")), "keep")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("untitled 200.txt")), "keep 200")
        XCTAssertEqual(try names().count, 201)
    }

    func testFillsAGapInTheNumbering() throws {
        try Data().write(to: directory.appendingPathComponent("untitled.md"))
        try Data().write(to: directory.appendingPathComponent("untitled 3.md"))
        XCTAssertEqual(try NewFile.create(in: directory, ext: "md").lastPathComponent, "untitled 2.md")
    }

    func testNamesWithNoExtension() throws {
        try Data("keep".utf8).write(to: directory.appendingPathComponent("untitled"))
        let created = try NewFile.create(in: directory, ext: "")
        XCTAssertEqual(created.lastPathComponent, "untitled 2")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("untitled")), "keep")
    }

    func testReadOnlyDirectoryFailsCleanlyWithNothingCreated() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try NewFile.create(in: directory, ext: "txt")) { error in
            XCTAssertEqual(error as? NewFileError, .failed(EACCES))
        }
        XCTAssertEqual(try names(), [])
    }

    func testMissingDirectoryFails() {
        let missing = directory.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try NewFile.create(in: missing, ext: "txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDoesNotFollowADanglingSymlinkAtTheName() throws {
        let victim = directory.appendingPathComponent("elsewhere.txt")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("untitled.txt"), withDestinationURL: victim)
        let created = try NewFile.create(in: directory, ext: "txt")
        XCTAssertEqual(created.lastPathComponent, "untitled 2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path), "a symlink's target must not be created")
    }
}
