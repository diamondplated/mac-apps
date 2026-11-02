import Foundation
import XCTest
import PhotoIO

final class RecoverableTrashTests: XCTestCase {
    func testTrashReceiptRestoresBytesAndRefusesOverwrite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("photo")
        let destination = root.appendingPathComponent("fixture-trash")
        let bytes = Data("photo bytes".utf8)
        try bytes.write(to: source)
        let trash = RecoverableTrash { url in
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let receipt = try trash.trash(source)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let trashURL = try XCTUnwrap(receipt.trashURL)
        try Data("replacement".utf8).write(to: source)
        XCTAssertThrowsError(try trash.restore(originalURL: receipt.originalURL, trashURL: trashURL))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        try fm.removeItem(at: source)
        try trash.restore(originalURL: receipt.originalURL, trashURL: trashURL)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }
}
