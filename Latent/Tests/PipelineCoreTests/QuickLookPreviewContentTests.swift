import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotoQuickLook

final class QuickLookPreviewContentTests: XCTestCase {
    func testReplyBytesPreserveOrientationAndDimensionCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ql-reply-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8,
                                              bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let content = try QuickLookPreviewContent.load(url: url, maxDimension: 96)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(content.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(preview.height, 96)
        XCTAssertLessThan(preview.width, preview.height)
        XCTAssertEqual(content.size, CGSize(width: preview.width, height: preview.height))
    }

    func testInvalidAndUnsupportedSourcesFailInsteadOfReplyingWithEmptyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ql-errors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        XCTAssertThrowsError(try QuickLookPreviewContent.load(url: corrupt))
        XCTAssertThrowsError(try QuickLookPreviewContent.load(url: root.appendingPathComponent("missing.jpg")))
        XCTAssertThrowsError(try QuickLookPreviewContent.load(url: root.appendingPathComponent("unsupported.txt")))
    }
}
