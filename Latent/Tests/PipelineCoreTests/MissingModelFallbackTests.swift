import XCTest
import Foundation
import PipelineCore
import EnhancementStages

final class MissingModelFallbackTests: XCTestCase {
    func testEmptyExclusiveModelRootPreservesFallbacks() async throws {
        guard let path = ProcessInfo.processInfo.environment["PV_MODELS_DIR"],
              try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
            throw XCTSkip("Run with PV_MODELS_DIR set to an empty private directory to isolate missing models.")
        }
        let input = ImageBuffer(width: 4, height: 3, format: .working, pixels: Data(count: 4 * 3 * 8))
        let artifact = try await ArtifactRemoval().process(input: input, params: .init(), progress: .noop)
        let denoise = try await Denoise().process(input: input, params: .init(), progress: .noop)
        XCTAssertEqual(artifact.contentHash, input.contentHash)
        XCTAssertEqual(denoise.contentHash, input.contentHash)
        let upscale = try await Upscale().process(input: input, params: .init(scale: 2), progress: .noop)
        XCTAssertEqual(upscale.width, 8)
        XCTAssertEqual(upscale.height, 6)
    }
}
