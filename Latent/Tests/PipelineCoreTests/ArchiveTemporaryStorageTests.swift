import Foundation
import XCTest
import PhotoIO

final class ArchiveTemporaryStorageTests: XCTestCase {
    func testSweepPreservesActiveUnmarkedAndSymlinkDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let active = try ArchiveTemporaryStorage.createDirectory(root: root)
        defer { try? ArchiveTemporaryStorage.remove(active) }
        let stale = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        let unmarked = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        for dir in [stale, unmarked] { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        try Data().write(to: stale.appendingPathComponent(".latent-extraction-lease-v1"))
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("photo"))
        let link = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        for dir in [active, unmarked, link, outside] { XCTAssertTrue(fm.fileExists(atPath: dir.path)) }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("photo")), Data("keep".utf8))
    }
}
