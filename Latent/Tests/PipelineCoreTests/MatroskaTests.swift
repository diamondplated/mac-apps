import XCTest
import VerificationSupport

final class MatroskaTests: XCTestCase {
    func testEveryFixtureCodecDecodesInFullAndThumbnails() async throws {
        try await verifyMatroskaFixturesDecode()
    }

    func testAudioLandsWithinTwoMillisecondsOfVideoForEveryCodec() async throws {
        try await verifyMatroskaAudioSync()
    }

    func testLacingLiveAndCutOffFilesIndexExactly() async throws {
        try await verifyMatroskaLacingAndDamage()
    }

    func testUnplayableFilesFailWithAReason() async throws {
        try await verifyMatroskaRejectsUnplayableFiles()
    }
}
