import XCTest
import PhotoIO

final class ArchiveTechnicalListingTests: XCTestCase {
    func testAcceptsMembersAndRejectsHiddenContinuationBeforeExtraction() throws {
        let archive = URL(fileURLWithPath: "/tmp/photos.7z")
        let header = "7-Zip\nPath = /tmp/photos.7z\nType = 7z\n----------\n"
        let paths = try ArchiveExtractor.sevenZipMemberPaths(header + "Path = photo.jpg\nSize = 4\n\nPath = album\nFolder = +\n", archiveURL: archive)
        XCTAssertEqual(paths, ["photo.jpg", "album"])
        for body in ["Path = ok\n../../escape", "Path = ok\r../../escape", "Path = /tmp/photos.7z", "Path = .latent-extraction-lease-v1", "Size = 1", "Path = ok\nPath = ../escape", "Path = ok\nUnknown = field"] {
            XCTAssertThrowsError(try ArchiveExtractor.sevenZipMemberPaths(header + body, archiveURL: archive), body)
        }
        XCTAssertThrowsError(try ArchiveExtractor.sevenZipMemberPaths("Path = photo.jpg", archiveURL: archive))
    }
}
