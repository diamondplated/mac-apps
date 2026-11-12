import Foundation

/// DDC/CI messages as sent over the display's I2C channel (VESA DDC/CI 1.1). The
/// host writes to the display at 7-bit address 0x37 (0x6E on the wire) from source
/// 0x51; the I2C layer sends those two address bytes, so the packets here start at
/// the length byte while the checksum still covers both addresses.
public enum DDC {
    public static let chipAddress: UInt8 = 0x37
    public static let hostAddress: UInt8 = 0x51
    static let displayWriteAddress: UInt8 = 0x6E
    /// Replies are checksummed against the host's virtual address 0x50.
    static let replyVirtualAddress: UInt8 = 0x50
    public static let replyLength = 11

    public enum Code: UInt8 {
        case brightness = 0x10
        case volume = 0x62
    }

    public static func checksum(_ start: UInt8, _ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(start, ^)
    }

    /// "Get VCP Feature": 82 01 <code> <checksum>.
    public static func readRequest(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(displayWriteAddress ^ hostAddress, body)]
    }

    /// "Set VCP Feature": 84 03 <code> <high> <low> <checksum>.
    public static func writeRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(displayWriteAddress ^ hostAddress, body)]
    }

    public struct Value: Equatable {
        public var current: Int
        public var maximum: Int
        public init(current: Int, maximum: Int) { self.current = current; self.maximum = maximum }
    }

    /// Parses a "Get VCP Feature Reply" as read back from the display:
    /// 6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>.
    /// Anything malformed, for another code, unsupported, or with a zero maximum is nil.
    public static func parseReply(_ reply: [UInt8], expecting code: UInt8) -> Value? {
        guard reply.count >= replyLength else { return nil }
        let bytes = Array(reply.prefix(replyLength))
        guard bytes[0] == displayWriteAddress, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0x00, bytes[4] == code,
              checksum(replyVirtualAddress, bytes[0..<10]) == bytes[10] else { return nil }
        let maximum = Int(bytes[6]) << 8 | Int(bytes[7])
        let current = Int(bytes[8]) << 8 | Int(bytes[9])
        guard maximum > 0 else { return nil }
        return Value(current: min(current, maximum), maximum: maximum)
    }
}

/// One press of a brightness or volume key moves a sixteenth of the range, like the built-in display.
public enum Steps {
    public static let count = 16

    public static func next(current: Int, maximum: Int, up: Bool) -> Int {
        guard maximum > 0 else { return 0 }
        let clamped = min(max(current, 0), maximum)
        // Too few values for sixteen distinct steps: move one value at a time.
        if maximum < count { return min(max(clamped + (up ? 1 : -1), 0), maximum) }
        let position = Double(clamped) * Double(count) / Double(maximum)
        // A value written by an earlier step was rounded to a whole number; treat anything
        // within half a value of a step as on it, so a step never repeats.
        let tolerance = Double(count) / Double(maximum) / 2 + 1e-9
        let target = up ? (position + tolerance).rounded(.down) + 1 : (position - tolerance).rounded(.up) - 1
        let step = min(max(target, 0), Double(count))
        return Int((step * Double(maximum) / Double(count)).rounded())
    }

    public static func fraction(current: Int, maximum: Int) -> Double {
        guard maximum > 0 else { return 0 }
        return min(max(Double(current) / Double(maximum), 0), 1)
    }
}

/// A display's own volume with mute: muting writes zero and remembers the level,
/// and the next volume or mute key brings it back.
public struct DisplayVolume: Equatable {
    public private(set) var level: Int
    public let maximum: Int
    public private(set) var mutedLevel: Int?
    public init(level: Int, maximum: Int) {
        self.maximum = max(maximum, 0)
        self.level = min(max(level, 0), self.maximum)
    }

    public var isMuted: Bool { mutedLevel != nil }

    /// The value to write to the display.
    public mutating func step(up: Bool) -> Int {
        if let restored = mutedLevel { level = restored; mutedLevel = nil }
        level = Steps.next(current: level, maximum: maximum, up: up)
        return level
    }

    public mutating func toggleMute() -> Int {
        if let restored = mutedLevel { level = restored; mutedLevel = nil; return level }
        mutedLevel = level
        return 0
    }
}

/// Some displays misbehave when written too fast: write at most once per interval
/// and keep only the newest value while waiting.
public struct WriteLimiter {
    public let interval: TimeInterval
    public private(set) var lastWrite: TimeInterval?
    public private(set) var pending: Int?
    public init(interval: TimeInterval = 0.06) { self.interval = interval }

    public enum Decision: Equatable {
        /// Write this now.
        case write(Int)
        /// Call `fire` at this time.
        case schedule(at: TimeInterval)
        /// A write is already scheduled; it will carry this value.
        case coalesced
    }

    public mutating func request(_ value: Int, at now: TimeInterval) -> Decision {
        if pending != nil { pending = value; return .coalesced }
        if let lastWrite, now - lastWrite < interval {
            pending = value
            return .schedule(at: lastWrite + interval)
        }
        lastWrite = now
        return .write(value)
    }

    /// The scheduled moment arrived: returns the newest value to write, if any.
    public mutating func fire(at now: TimeInterval) -> Int? {
        guard let value = pending else { return nil }
        pending = nil
        lastWrite = now
        return value
    }
}
