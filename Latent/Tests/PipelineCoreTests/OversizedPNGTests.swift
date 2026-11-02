import XCTest
import VerificationSupport

final class OversizedPNGTests: XCTestCase {
    func testReal400MPPNGRejectsEnhancementAndStillDecodesBoundedPreview() throws {
        try verifyOversizedPNG()
    }
}
