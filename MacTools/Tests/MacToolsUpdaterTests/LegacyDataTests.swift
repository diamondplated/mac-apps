import Foundation
import XCTest
@testable import MacTools

final class LegacyDataTests: XCTestCase {
    func testRemovesOnlyWhatTheRetiredUtilitiesStored() throws {
        let suite = "LegacyDataTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in LegacyData.preferenceKeys { defaults.set(true, forKey: key) }
        defaults.set("kept", forKey: "unrelated")

        let support = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let baselines = support.appendingPathComponent("Mac Tools/Storage Baselines", isDirectory: true)
        try FileManager.default.createDirectory(at: baselines, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: baselines.appendingPathComponent("abc.json"))
        let neighbor = support.appendingPathComponent("Mac Tools/keep.txt")
        try Data("keep".utf8).write(to: neighbor)

        LegacyData.remove(defaults: defaults, applicationSupport: support)

        for key in LegacyData.preferenceKeys { XCTAssertNil(defaults.object(forKey: key)) }
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: baselines.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))

        // Running again with nothing left is harmless.
        LegacyData.remove(defaults: defaults, applicationSupport: support)
    }
}
