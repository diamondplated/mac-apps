import XCTest
import VerificationSupport

final class BurstTests: XCTestCase {
    func testGrouping() async throws { try await verifyBurstGrouping() }
    func testRanksSharpest() async throws { try await verifyBurstRanksSharpest() }
    func testReasonOrdering() async throws { try await verifyBurstReasonOrdering() }
    func testThresholds() async throws { try await verifyBurstThresholds() }
    func testCache() async throws { try await verifyBurstCache() }
    @MainActor func testKeepActions() async throws { try await verifyBurstKeepActions() }
}
