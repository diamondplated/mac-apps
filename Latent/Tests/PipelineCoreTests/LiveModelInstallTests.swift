import XCTest
import Foundation

final class LiveModelInstallTests: XCTestCase {
    func testValidModelInstalledAfterCachedFallbackChangesOutputWithoutRelaunch() throws {
        // The child owns its PV_MODELS_DIR and uses the actual shared manager,
        // Upscale, model compiler and pipeline. No env mutations in XCTest.
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("pv-pipeline")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [sibling, root.appendingPathComponent(".build/debug/pv-pipeline")]
        let executable = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
                                      "Build pv-pipeline before running the model-install proof")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--verify-model-install"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("PASS valid model install replaces cached fallback"), text)
    }
}
