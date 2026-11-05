import XCTest
import VerificationSupport

final class AVITests: XCTestCase {
    func testEveryFixtureCodecDecodesInFullAndThumbnails() async throws {
        try await verifyAVIFixturesDecode()
    }

    func testVideoAndAudioLandWhereFfmpegPlacesThem() async throws {
        try await verifyAVIAudioSync()
    }

    func testOpenDMLLegacyScannedAndCutOffFilesIndexAlike() async throws {
        try await verifyAVIIndexes()
    }

    func testConstantBitrateAudioRecutOnPacketBoundariesDecodesExactly() async throws {
        try await verifyAVIRepacketizing()
    }

    func testUnplayableStreamsAndFilesFailWithAReason() async throws {
        try await verifyAVIRejectsUnplayable()
    }
}
