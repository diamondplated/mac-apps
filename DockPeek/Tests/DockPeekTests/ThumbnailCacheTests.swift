import AppKit
import XCTest
@testable import DockPeek

final class ThumbnailCacheTests: XCTestCase {
    func testLeastRecentlyUsedThumbnailIsEvictedAtTheLimit() async {
        let cache = ThumbnailCache(limit: 2)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        await cache.set(1, image: image)
        await cache.set(2, image: image)
        _ = await cache.get(1)
        await cache.set(3, image: image)

        let count = await cache.count
        let first = await cache.get(1)
        let second = await cache.get(2)
        let third = await cache.get(3)
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(third)
    }
}
