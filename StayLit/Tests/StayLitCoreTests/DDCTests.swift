import XCTest
@testable import StayLitCore

final class DDCTests: XCTestCase {
    /// The widely published brightness read: 6E 51 82 01 10 AC on the wire.
    func testReadRequestMatchesKnownBytes() {
        XCTAssertEqual(DDC.readRequest(0x10), [0x82, 0x01, 0x10, 0xAC])
        XCTAssertEqual(DDC.readRequest(0x62), [0x82, 0x01, 0x62, 0xDE])
    }

    /// Set brightness to 50: 6E 51 84 03 10 00 32 9A on the wire.
    func testWriteRequestMatchesKnownBytes() {
        XCTAssertEqual(DDC.writeRequest(0x10, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        XCTAssertEqual(DDC.writeRequest(0x62, value: 0x0123), [0x84, 0x03, 0x62, 0x01, 0x23, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x62 ^ 0x01 ^ 0x23])
    }

    func testChecksumCoversBothAddresses() {
        // Dropping either address from the checksum changes the byte the display checks.
        let packet = DDC.readRequest(0x10)
        XCTAssertNotEqual(packet.last, DDC.checksum(0x6E, packet.dropLast()))
        XCTAssertNotEqual(packet.last, DDC.checksum(0x51, packet.dropLast()))
    }

    /// Brightness 50 of 100: 6E 88 02 00 10 00 00 64 00 32 F2.
    let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]

    func testParsesKnownReply() {
        XCTAssertEqual(DDC.parseReply(reply, expecting: 0x10), DDC.Value(current: 50, maximum: 100))
        // Trailing bytes from a longer read are ignored.
        XCTAssertEqual(DDC.parseReply(reply + [0x00], expecting: 0x10), DDC.Value(current: 50, maximum: 100))
    }

    func testRejectsBadReplies() {
        var badChecksum = reply; badChecksum[10] ^= 0x01
        XCTAssertNil(DDC.parseReply(badChecksum, expecting: 0x10))
        XCTAssertNil(DDC.parseReply(reply, expecting: 0x62), "a reply for another code")
        XCTAssertNil(DDC.parseReply(Array(reply.prefix(10)), expecting: 0x10), "too short")
        XCTAssertNil(DDC.parseReply([UInt8](repeating: 0, count: 11), expecting: 0x10), "a display that does not answer")
        var unsupported = reply; unsupported[3] = 0x01; unsupported[10] ^= 0x01
        XCTAssertNil(DDC.parseReply(unsupported, expecting: 0x10), "result code 1 means unsupported")
        var zeroMax = reply; zeroMax[7] = 0; zeroMax[10] ^= 0x64
        XCTAssertNil(DDC.parseReply(zeroMax, expecting: 0x10))
    }

    func testCurrentAboveMaximumIsClamped() {
        var high: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x96]
        high.append(DDC.checksum(0x50, high))
        XCTAssertEqual(DDC.parseReply(high, expecting: 0x62), DDC.Value(current: 100, maximum: 100))
    }

    func testSixteenStepsLikeTheBuiltInDisplay() {
        XCTAssertEqual(Steps.next(current: 50, maximum: 100, up: true), 56)
        XCTAssertEqual(Steps.next(current: 50, maximum: 100, up: false), 44)
        XCTAssertEqual(Steps.next(current: 100, maximum: 100, up: true), 100)
        XCTAssertEqual(Steps.next(current: 0, maximum: 100, up: false), 0)
        XCTAssertEqual(Steps.next(current: 0, maximum: 100, up: true), 6)
        // Walking up from zero reaches the maximum in exactly sixteen presses, and back.
        var value = 0, presses = 0
        while value < 100 { value = Steps.next(current: value, maximum: 100, up: true); presses += 1 }
        XCTAssertEqual(presses, 16)
        while value > 0 { value = Steps.next(current: value, maximum: 100, up: false); presses -= 1 }
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(Steps.next(current: 5, maximum: 0, up: true), 0)
        XCTAssertEqual(Steps.fraction(current: 25, maximum: 100), 0.25)
    }

    func testMuteRemembersLevel() {
        var volume = DisplayVolume(level: 40, maximum: 100)
        XCTAssertEqual(volume.toggleMute(), 0)
        XCTAssertTrue(volume.isMuted)
        XCTAssertEqual(volume.toggleMute(), 40)
        XCTAssertFalse(volume.isMuted)
        _ = volume.toggleMute()
        XCTAssertEqual(volume.step(up: true), 44, "a volume key unmutes from the remembered level")
        XCTAssertFalse(volume.isMuted)
    }

    func testLimiterWritesAtMostOncePerIntervalAndKeepsNewest() {
        var limiter = WriteLimiter(interval: 0.06)
        XCTAssertEqual(limiter.request(10, at: 1.00), .write(10))
        XCTAssertEqual(limiter.request(11, at: 1.02), .schedule(at: 1.06))
        XCTAssertEqual(limiter.request(12, at: 1.03), .coalesced)
        XCTAssertEqual(limiter.request(13, at: 1.05), .coalesced)
        XCTAssertEqual(limiter.fire(at: 1.06), 13, "only the newest value is written")
        XCTAssertNil(limiter.fire(at: 1.07), "nothing left to write")
        XCTAssertEqual(limiter.request(14, at: 1.09), .schedule(at: 1.12), "the interval counts from the deferred write")
        XCTAssertEqual(limiter.fire(at: 1.12), 14)
        XCTAssertEqual(limiter.request(15, at: 1.30), .write(15))
    }
}
