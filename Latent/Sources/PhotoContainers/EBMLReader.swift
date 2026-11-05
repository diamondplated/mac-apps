import Foundation

/// Positional reads through one reusable window. Walking the block headers of
/// a multi-gigabyte file becomes a single forward pass of I/O, and nothing is
/// memory-mapped: a file that is truncated while it is open (a recording
/// still being written, a network volume going away) produces a short read
/// here instead of a SIGBUS in the viewer.
final class WindowedFile {
    let size: Int64
    private let fd: Int32
    private let buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private(set) var windowStart: Int64 = 0
    private(set) var windowCount = 0

    init(url: URL, capacity: Int = 512 * 1024) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ContainerError.unreadable(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw ContainerError.unreadable(code)
        }
        // Sequential read-ahead is exactly the access pattern of an index pass.
        _ = fcntl(fd, F_RDAHEAD, 1)
        self.fd = fd
        self.size = Int64(info.st_size)
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
        close(fd)
    }

    /// Makes `[offset, offset + count)` addressable through `byte(_:)`.
    /// Returns false when the range runs past the end of the file; whatever
    /// part of it exists is still loaded.
    @discardableResult
    func ensure(_ offset: Int64, _ count: Int) throws -> Bool {
        precondition(count <= capacity)
        if offset >= windowStart, offset + Int64(count) <= windowStart + Int64(windowCount) {
            return true
        }
        try fill(at: offset)
        return offset + Int64(count) <= windowStart + Int64(windowCount)
    }

    @inline(__always)
    func byte(_ offset: Int64) -> UInt8 {
        buffer[Int(offset - windowStart)]
    }

    /// Bytes available in the window from `offset` (0 when outside it).
    func available(from offset: Int64) -> Int {
        guard offset >= windowStart else { return 0 }
        return max(0, Int(windowStart + Int64(windowCount) - offset))
    }

    /// Copies a byte range out of the file, for small payloads such as
    /// CodecPrivate. Reads past the end of the file are truncated.
    func data(at offset: Int64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return Data() }
        let wanted = Int(min(Int64(count), size - offset))
        var out = Data(count: wanted)
        let got = try out.withUnsafeMutableBytes { raw -> Int in
            try readFully(into: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: wanted, at: offset)
        }
        if got < wanted { out.removeSubrange(got..<wanted) }
        return out
    }

    private func fill(at offset: Int64) throws {
        windowStart = offset
        windowCount = 0
        guard offset < size else { return }
        windowCount = try readFully(into: buffer, count: capacity, at: offset)
    }

    private func readFully(into destination: UnsafeMutablePointer<UInt8>, count: Int, at offset: Int64) throws -> Int {
        var filled = 0
        while filled < count {
            let n = pread(fd, destination + filled, count - filled, off_t(offset + Int64(filled)))
            if n < 0 {
                if errno == EINTR { continue }
                throw ContainerError.unreadable(errno)
            }
            if n == 0 { break }
            filled += n
        }
        return filled
    }
}

/// One EBML element header. `size == nil` is the "unknown size" encoding a
/// live writer uses for the Segment and Clusters it has not finished.
struct EBMLElement {
    let id: UInt32
    let headerOffset: Int64
    let dataOffset: Int64
    let size: Int64?

    var end: Int64? { size.map { dataOffset + $0 } }
}

extension WindowedFile {
    /// Reads the element header at `offset`, or nil when the bytes there are
    /// not a valid header or run past the end of the file.
    func element(at offset: Int64) throws -> EBMLElement? {
        guard offset < size else { return nil }
        try ensure(offset, 12)
        let avail = available(from: offset)
        guard avail > 0 else { return nil }

        let first = byte(offset)
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, idLength < avail else { return nil }
        var id = UInt32(first)
        for i in 1..<idLength {
            id = (id << 8) | UInt32(byte(offset + Int64(i)))
        }

        let sizeOffset = offset + Int64(idLength)
        let sizeFirst = byte(sizeOffset)
        guard sizeFirst != 0 else { return nil }
        let sizeLength = sizeFirst.leadingZeroBitCount + 1
        guard idLength + sizeLength <= avail else { return nil }
        var value = UInt64(sizeFirst & (0xFF >> sizeLength))
        var allOnes = value == UInt64(0xFF >> sizeLength)
        for i in 1..<sizeLength {
            let b = byte(sizeOffset + Int64(i))
            allOnes = allOnes && b == 0xFF
            value = (value << 8) | UInt64(b)
        }
        let dataOffset = sizeOffset + Int64(sizeLength)
        if allOnes {
            return EBMLElement(id: id, headerOffset: offset, dataOffset: dataOffset, size: nil)
        }
        guard value <= UInt64(Int64.max / 2) else { return nil }
        return EBMLElement(id: id, headerOffset: offset, dataOffset: dataOffset, size: Int64(value))
    }

    func unsigned(_ element: EBMLElement) throws -> UInt64 {
        guard let size = element.size, size > 0, size <= 8 else { return 0 }
        try ensure(element.dataOffset, Int(size))
        guard available(from: element.dataOffset) >= Int(size) else { return 0 }
        var value: UInt64 = 0
        for i in 0..<Int64(size) {
            value = (value << 8) | UInt64(byte(element.dataOffset + i))
        }
        return value
    }

    func float(_ element: EBMLElement) throws -> Double {
        guard let size = element.size else { return 0 }
        let raw = try unsigned(element)
        switch size {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8: return Double(bitPattern: raw)
        default: return 0
        }
    }

    func string(_ element: EBMLElement) throws -> String {
        guard let size = element.size, size > 0, size <= 4096 else { return "" }
        var bytes = try data(at: element.dataOffset, count: Int(size))
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    func binary(_ element: EBMLElement, limit: Int = 16 * 1024 * 1024) throws -> Data {
        guard let size = element.size, size > 0, size <= Int64(limit) else { return Data() }
        return try data(at: element.dataOffset, count: Int(size))
    }

    /// Children of a master element with a known size, clipped to the file.
    func children(of parent: EBMLElement) throws -> [EBMLElement] {
        guard let end = parent.end else { return [] }
        let limit = min(end, size)
        var out: [EBMLElement] = []
        var cursor = parent.dataOffset
        while cursor < limit, let child = try element(at: cursor), let childEnd = child.end {
            out.append(child)
            cursor = childEnd
        }
        return out
    }
}

/// Element IDs this reader consumes (Matroska specification, RFC 9559).
enum MKV {
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067

    static let seekHead: UInt32 = 0x114D9B74
    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B
    static let cluster: UInt32 = 0x1F43B675
    static let cues: UInt32 = 0x1C53BB6B
    static let chapters: UInt32 = 0x1043A770
    static let tags: UInt32 = 0x1254C367
    static let attachments: UInt32 = 0x1941A469

    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let range: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254

    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB

    /// IDs that can only appear directly under the Segment. Meeting one while
    /// walking an unknown-size Cluster means that Cluster has ended.
    static let segmentLevel: Set<UInt32> = [
        seekHead, info, tracks, cluster, cues, chapters, tags, attachments, ebml, segment,
    ]
}
