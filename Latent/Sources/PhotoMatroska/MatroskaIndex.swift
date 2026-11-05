import Foundation

/// One coded frame inside a Matroska file: where its bytes are and when it
/// plays. Laced blocks (several audio frames sharing one block header) yield
/// one entry per frame, all carrying the block's timestamp.
public struct MatroskaFrame: Sendable, Equatable {
    /// Absolute byte offset of the frame's payload in the file.
    public var offset: Int64
    public var size: Int32
    /// Presentation timestamp of the enclosing block, in TimestampScale ticks.
    public var timestamp: Int64
    /// BlockDuration in ticks, or -1 when the block did not carry one.
    public var blockDuration: Int64
    public var laceIndex: UInt16
    public var laceCount: UInt16
    public var isKeyframe: Bool
    /// The first eight payload bytes, big-endian and zero-padded. Captured
    /// for audio tracks only, so packet durations can be read from codec
    /// headers (an Opus TOC byte) without a second pass over the file.
    public var prefix: UInt64
}

public struct MatroskaTrack: Sendable {
    public enum Kind: Sendable, Equatable {
        case video
        case audio
        case subtitle
        case other(UInt64)
    }

    public var number: UInt64 = 0
    public var kind: Kind = .other(0)
    public var codecID = ""
    public var codecPrivate = Data()
    public var name: String?
    /// BCP 47 when the file has it, otherwise the ISO 639-2 code. Nil for
    /// "und". The specification's default when the element is absent is
    /// English.
    public var language: String? = "eng"
    public var isEnabled = true
    public var isDefault = true
    public var isForced = false
    /// Nanoseconds per frame, when the muxer declared a constant rate.
    public var defaultDuration: UInt64?
    public var codecDelay: UInt64?

    public var pixelWidth = 0
    public var pixelHeight = 0
    public var displayWidth: Int?
    public var displayHeight: Int?
    public var displayUnit = 0
    public var colour = MatroskaColour()

    public var samplingFrequency = 8000.0
    public var outputSamplingFrequency: Double?
    public var channels = 1
    public var bitDepth: Int?

    /// Set when ContentEncodings transform the stored frames (header
    /// stripping, zlib, encryption): the bytes on disk are then not the
    /// codec's bitstream and cannot be handed to a decoder by reference.
    public var contentEncoding: String?

    public var frames: [MatroskaFrame] = []

    public var kindName: String {
        switch kind {
        case .video: "video"
        case .audio: "audio"
        case .subtitle: "subtitle"
        case .other: "data"
        }
    }
}

/// ISO/IEC 23091-2 code points from the track's Colour element. Zero or 2
/// means "unspecified" and is left to the bitstream.
public struct MatroskaColour: Sendable, Equatable {
    public var matrix = 2
    public var transfer = 2
    public var primaries = 2
    /// 1 = broadcast (limited), 2 = full, 0/3 = unspecified or derived.
    public var range = 0
}

/// Everything Latent needs from a Matroska or WebM file to play it through
/// AVFoundation: track descriptions and the byte range and timing of every
/// frame. Built by one forward pass that reads element and block headers and
/// skips over payloads.
public struct MatroskaIndex: Sendable {
    public var docType = "matroska"
    /// Nanoseconds per timestamp tick.
    public var timestampScale: UInt64 = 1_000_000
    /// Declared segment duration in seconds, when the muxer wrote one.
    public var duration: Double?
    public var tracks: [MatroskaTrack] = []
    /// False when the file ended early (a truncated download, a recording
    /// that is still being written) or reading stopped at the requested
    /// time limit. The frames that were read are still valid.
    public var isComplete = true

    /// Indexes `url`. With `limit`, stops at the first Cluster that starts
    /// more than `limit` seconds after the first one, which is all a
    /// thumbnail needs.
    ///
    /// Reading is one pass over the file, so a long recording on a slow
    /// volume takes a while: `progress` receives the fraction of the file
    /// read so far (0...1), a few hundred times at most, on the calling
    /// thread. Checks Swift task cancellation between clusters and throws
    /// `CancellationError` when the caller has gone away.
    public static func read(url: URL, limit: Double? = nil,
                            progress: ((Double) -> Void)? = nil) throws -> MatroskaIndex {
        let file = try WindowedFile(url: url)
        var reader = IndexReader(file: file, limit: limit, progress: progress)
        return try reader.run()
    }
}

private struct IndexReader {
    let file: WindowedFile
    let limit: Double?
    let progress: ((Double) -> Void)?
    var index = MatroskaIndex()
    var trackSlots: [UInt64: Int] = [:]
    var capturesPrefix: [Bool] = []
    var blocksSinceCancellationCheck = 0
    var reportedProgress = 0.0
    /// The first Cluster's timestamp: `limit` counts from where the file
    /// starts, which need not be zero (a capture remuxed with its original
    /// clock).
    var firstClusterTimestamp: Int64?

    init(file: WindowedFile, limit: Double?, progress: ((Double) -> Void)?) {
        self.file = file
        self.limit = limit
        self.progress = progress
    }

    mutating func run() throws -> MatroskaIndex {
        guard let header = try file.element(at: 0), header.id == MKV.ebml, let headerEnd = header.end else {
            throw MatroskaError.notMatroska
        }
        for child in try file.children(of: header) where child.id == MKV.docType {
            index.docType = try file.string(child)
        }
        guard index.docType == "matroska" || index.docType == "webm" else {
            throw MatroskaError.unsupportedDocType(index.docType)
        }

        // EBML Void elements may sit between the header and the Segment.
        var cursor = headerEnd
        var segment: EBMLElement?
        while let element = try file.element(at: cursor) {
            if element.id == MKV.segment { segment = element; break }
            guard let end = element.end else { break }
            cursor = end
        }
        guard let segment else { throw MatroskaError.noSegment }

        let segmentEnd = min(segment.end ?? file.size, file.size)
        if let end = segment.end, end > file.size { index.isComplete = false }

        var position = segment.dataOffset
        topLevel: while position < segmentEnd {
            guard let element = try file.element(at: position) else {
                // Damage between clusters: look for the next Cluster rather
                // than dropping the rest of the recording.
                if let next = try resync(from: position + 1, limit: segmentEnd) {
                    index.isComplete = false
                    position = next
                    continue
                }
                index.isComplete = false
                break
            }
            switch element.id {
            case MKV.info:
                try readInfo(element)
            case MKV.tracks:
                try readTracks(element)
            case MKV.cluster:
                reportProgress(at: element.headerOffset)
                let outcome: (next: Int64, stopped: Bool)
                do {
                    outcome = try readCluster(element, segmentEnd: segmentEnd)
                } catch is BlockTruncated {
                    // The file shrank while it was being read.
                    index.isComplete = false
                    break topLevel
                }
                if outcome.stopped {
                    index.isComplete = false
                    break topLevel
                }
                position = outcome.next
                continue
            case MKV.segment, MKV.ebml:
                // A second, concatenated file. Matroska players treat it as
                // a separate presentation; so do we.
                break topLevel
            default:
                break
            }
            guard let end = element.end else {
                // An unknown-size element other than a Cluster cannot be
                // skipped; whatever follows it is unreachable.
                index.isComplete = false
                break
            }
            if end > file.size { index.isComplete = false }
            position = end
        }

        progress?(1)
        return index
    }

    // MARK: Segment information

    private mutating func readInfo(_ info: EBMLElement) throws {
        var rawDuration: Double?
        for child in try file.children(of: info) {
            switch child.id {
            case MKV.timestampScale:
                let scale = try file.unsigned(child)
                if scale > 0 { index.timestampScale = scale }
            case MKV.duration:
                rawDuration = try file.float(child)
            default:
                break
            }
        }
        if let rawDuration, rawDuration.isFinite, rawDuration > 0 {
            index.duration = rawDuration * Double(index.timestampScale) / 1_000_000_000
        }
    }

    private mutating func readTracks(_ tracks: EBMLElement) throws {
        for entry in try file.children(of: tracks) where entry.id == MKV.trackEntry {
            var track = MatroskaTrack()
            var bcp47: String?
            for child in try file.children(of: entry) {
                switch child.id {
                case MKV.trackNumber: track.number = try file.unsigned(child)
                case MKV.trackType:
                    switch try file.unsigned(child) {
                    case 1: track.kind = .video
                    case 2: track.kind = .audio
                    case 17: track.kind = .subtitle
                    case let other: track.kind = .other(other)
                    }
                case MKV.flagEnabled: track.isEnabled = try file.unsigned(child) != 0
                case MKV.flagDefault: track.isDefault = try file.unsigned(child) != 0
                case MKV.flagForced: track.isForced = try file.unsigned(child) != 0
                case MKV.defaultDuration:
                    let value = try file.unsigned(child)
                    track.defaultDuration = value > 0 ? value : nil
                case MKV.name: track.name = try file.string(child)
                case MKV.language: track.language = try file.string(child)
                case MKV.languageBCP47: bcp47 = try file.string(child)
                case MKV.codecID: track.codecID = try file.string(child)
                case MKV.codecPrivate: track.codecPrivate = try file.binary(child)
                case MKV.codecDelay: track.codecDelay = try file.unsigned(child)
                case MKV.video: try readVideo(child, into: &track)
                case MKV.audio: try readAudio(child, into: &track)
                case MKV.contentEncodings: track.contentEncoding = try contentEncoding(child)
                default: break
                }
            }
            if let bcp47, !bcp47.isEmpty { track.language = bcp47 }
            if track.language == "und" || track.language?.isEmpty == true { track.language = nil }
            guard track.number > 0, trackSlots[track.number] == nil else { continue }
            trackSlots[track.number] = index.tracks.count
            capturesPrefix.append(track.kind == .audio)
            index.tracks.append(track)
        }
    }

    private func readVideo(_ video: EBMLElement, into track: inout MatroskaTrack) throws {
        for child in try file.children(of: video) {
            switch child.id {
            case MKV.pixelWidth: track.pixelWidth = Int(clamping: try file.unsigned(child))
            case MKV.pixelHeight: track.pixelHeight = Int(clamping: try file.unsigned(child))
            case MKV.displayWidth: track.displayWidth = Int(clamping: try file.unsigned(child))
            case MKV.displayHeight: track.displayHeight = Int(clamping: try file.unsigned(child))
            case MKV.displayUnit: track.displayUnit = Int(clamping: try file.unsigned(child))
            case MKV.colour:
                for colour in try file.children(of: child) {
                    let value = Int(clamping: try file.unsigned(colour))
                    switch colour.id {
                    case MKV.matrixCoefficients: track.colour.matrix = value
                    case MKV.transferCharacteristics: track.colour.transfer = value
                    case MKV.primaries: track.colour.primaries = value
                    case MKV.range: track.colour.range = value
                    default: break
                    }
                }
            default: break
            }
        }
    }

    private func readAudio(_ audio: EBMLElement, into track: inout MatroskaTrack) throws {
        for child in try file.children(of: audio) {
            switch child.id {
            case MKV.samplingFrequency:
                let rate = try file.float(child)
                if rate.isFinite, rate > 0 { track.samplingFrequency = rate }
            case MKV.outputSamplingFrequency:
                let rate = try file.float(child)
                if rate.isFinite, rate > 0 { track.outputSamplingFrequency = rate }
            case MKV.channels:
                track.channels = max(1, Int(clamping: try file.unsigned(child)))
            case MKV.bitDepth:
                track.bitDepth = Int(clamping: try file.unsigned(child))
            default: break
            }
        }
    }

    /// Describes the first ContentEncoding that alters frame data, or nil
    /// when the frames are stored as plain codec bitstream.
    private func contentEncoding(_ encodings: EBMLElement) throws -> String? {
        for encoding in try file.children(of: encodings) where encoding.id == MKV.contentEncoding {
            var scope: UInt64 = 1
            var type: UInt64 = 0
            var algorithm: UInt64 = 0
            for child in try file.children(of: encoding) {
                switch child.id {
                case MKV.contentEncodingScope: scope = try file.unsigned(child)
                case MKV.contentEncodingType: type = try file.unsigned(child)
                case MKV.contentCompression:
                    for setting in try file.children(of: child) where setting.id == MKV.contentCompAlgo {
                        algorithm = try file.unsigned(setting)
                    }
                default: break
                }
            }
            // Scope bit 1 is frame contents, bit 2 CodecPrivate. Either one
            // changes what a decoder would be handed.
            guard scope & 0b11 != 0 else { continue }
            if type == 1 { return "encryption" }
            switch algorithm {
            case 3: return "Matroska header compression"
            case 0: return "zlib compression"
            case 1: return "bzip2 compression"
            case 2: return "LZO compression"
            default: return "an unknown content encoding"
            }
        }
        return nil
    }

    // MARK: Clusters and blocks

    private mutating func readCluster(_ cluster: EBMLElement, segmentEnd: Int64) throws -> (next: Int64, stopped: Bool) {
        try checkCancellation(force: true)
        let declaredEnd = cluster.end.map { min($0, segmentEnd) }
        if let end = cluster.end, end > file.size { index.isComplete = false }
        let limitEnd = declaredEnd ?? segmentEnd
        var clusterTimestamp: Int64 = 0
        var position = cluster.dataOffset

        while position < limitEnd {
            guard let element = try file.element(at: position) else {
                // A torn write inside the last cluster: keep what came before.
                if let next = try resync(from: position + 1, limit: segmentEnd) {
                    index.isComplete = false
                    return (next, false)
                }
                index.isComplete = false
                return (segmentEnd, false)
            }
            if cluster.size == nil, MKV.segmentLevel.contains(element.id) {
                return (position, false)
            }
            switch element.id {
            case MKV.timestamp:
                clusterTimestamp = Int64(clamping: try file.unsigned(element))
                let first = firstClusterTimestamp ?? clusterTimestamp
                firstClusterTimestamp = first
                if let limit, seconds(clusterTimestamp - first) > limit {
                    return (position, true)
                }
            case MKV.simpleBlock:
                if let size = element.size {
                    try readBlock(at: element.dataOffset, size: size, clusterTimestamp: clusterTimestamp,
                                  keyframe: nil, blockDuration: -1)
                }
            case MKV.blockGroup:
                try readBlockGroup(element, clusterTimestamp: clusterTimestamp)
            default:
                break
            }
            guard let end = element.end else {
                index.isComplete = false
                return (segmentEnd, false)
            }
            position = end
        }
        return (declaredEnd ?? position, false)
    }

    private mutating func readBlockGroup(_ group: EBMLElement, clusterTimestamp: Int64) throws {
        var block: EBMLElement?
        var duration: Int64 = -1
        var referencesOthers = false
        for child in try file.children(of: group) {
            switch child.id {
            case MKV.block: block = child
            case MKV.blockDuration: duration = Int64(clamping: try file.unsigned(child))
            case MKV.referenceBlock: referencesOthers = true
            default: break
            }
        }
        guard let block, let size = block.size else { return }
        try readBlock(at: block.dataOffset, size: size, clusterTimestamp: clusterTimestamp,
                      keyframe: !referencesOthers, blockDuration: duration)
    }

    /// Parses a (Simple)Block header and its lacing, recording one frame per
    /// laced payload. `keyframe == nil` means "take it from SimpleBlock flags".
    private mutating func readBlock(at offset: Int64, size: Int64, clusterTimestamp: Int64,
                                    keyframe: Bool?, blockDuration: Int64) throws {
        try checkCancellation(force: false)
        let end = offset + size
        guard end <= file.size else {
            index.isComplete = false
            return
        }
        var cursor = offset

        let first = try byte(cursor)
        guard first != 0 else { return }
        let numberLength = first.leadingZeroBitCount + 1
        guard numberLength <= 8 else { return }
        var trackNumber = UInt64(first & (0xFF >> numberLength))
        for i in 1..<numberLength {
            trackNumber = (trackNumber << 8) | UInt64(try byte(cursor + Int64(i)))
        }
        cursor += Int64(numberLength)
        guard let slot = trackSlots[trackNumber] else { return }

        let relative = Int16(bitPattern: UInt16(try byte(cursor)) << 8 | UInt16(try byte(cursor + 1)))
        let flags = try byte(cursor + 2)
        cursor += 3
        let timestamp = clusterTimestamp + Int64(relative)
        let isKeyframe = keyframe ?? (flags & 0x80 != 0)

        var sizes: [Int64] = []
        let lacing = (flags >> 1) & 0b11
        if lacing == 0 {
            sizes = [end - cursor]
        } else {
            let count = Int(try byte(cursor)) + 1
            cursor += 1
            switch count == 1 ? 0 : lacing {
            case 0:
                break
            case 0b01: // Xiph
                for _ in 0..<(count - 1) {
                    var frameSize: Int64 = 0
                    var b: UInt8
                    repeat {
                        guard cursor < end else { return }
                        b = try byte(cursor)
                        cursor += 1
                        frameSize += Int64(b)
                    } while b == 0xFF
                    sizes.append(frameSize)
                }
            case 0b11: // EBML
                guard let (firstSize, length) = try vint(at: cursor, end: end) else { return }
                cursor += Int64(length)
                sizes.append(Int64(firstSize))
                for _ in 0..<max(0, count - 2) {
                    guard let (raw, length) = try vint(at: cursor, end: end) else { return }
                    cursor += Int64(length)
                    let bias = (Int64(1) << (7 * length - 1)) - 1
                    sizes.append(sizes[sizes.count - 1] + Int64(raw) - bias)
                }
            default: // Fixed
                let each = (end - cursor) / Int64(count)
                sizes = Array(repeating: each, count: count - 1)
            }
            let used = sizes.reduce(0, +)
            guard sizes.allSatisfy({ $0 >= 0 }), used <= end - cursor else { return }
            sizes.append(end - cursor - used)
        }

        let laceCount = UInt16(sizes.count)
        var frameOffset = cursor
        for (laceIndex, frameSize) in sizes.enumerated() {
            guard frameSize > 0, frameSize <= Int64(Int32.max) else {
                frameOffset += frameSize
                continue
            }
            let prefix = capturesPrefix[slot] ? try payloadPrefix(at: frameOffset, size: frameSize) : 0
            let isLast = laceIndex == sizes.count - 1
            index.tracks[slot].frames.append(MatroskaFrame(
                offset: frameOffset,
                size: Int32(frameSize),
                timestamp: timestamp,
                blockDuration: isLast ? blockDuration : -1,
                laceIndex: UInt16(laceIndex),
                laceCount: laceCount,
                isKeyframe: isKeyframe,
                prefix: prefix
            ))
            frameOffset += frameSize
        }
    }

    // MARK: Helpers

    private func seconds(_ ticks: Int64) -> Double {
        Double(ticks) * Double(index.timestampScale) / 1_000_000_000
    }

    @inline(__always)
    private func byte(_ offset: Int64) throws -> UInt8 {
        guard try file.ensure(offset, 1) else { throw BlockTruncated() }
        return file.byte(offset)
    }

    private func vint(at offset: Int64, end: Int64) throws -> (UInt64, Int)? {
        guard offset < end else { return nil }
        let first = try byte(offset)
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + Int64(length) <= end else { return nil }
        var value = UInt64(first & (0xFF >> length))
        for i in 1..<length {
            value = (value << 8) | UInt64(try byte(offset + Int64(i)))
        }
        return (value, length)
    }

    private func payloadPrefix(at offset: Int64, size: Int64) throws -> UInt64 {
        let count = Int(min(size, 8))
        try file.ensure(offset, count)
        guard file.available(from: offset) >= count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value <<= 8
            if i < count { value |= UInt64(file.byte(offset + Int64(i))) }
        }
        return value
    }

    /// Scans forward for the next Cluster ID after damaged bytes. Bounded so
    /// a file of garbage costs a fixed amount of reading.
    private func resync(from start: Int64, limit: Int64) throws -> Int64? {
        let scanLimit = min(limit, start + 64 * 1024 * 1024)
        var position = start
        while position + 4 <= scanLimit {
            try file.ensure(position, 4)
            let available = file.available(from: position)
            guard available >= 4 else { return nil }
            let stop = position + Int64(available) - 3
            var p = position
            while p < stop {
                if file.byte(p) == 0x1F, file.byte(p + 1) == 0x43, file.byte(p + 2) == 0xB6, file.byte(p + 3) == 0x75,
                   let element = try? file.element(at: p), element.id == MKV.cluster {
                    return p
                }
                p += 1
            }
            position = stop
        }
        return nil
    }

    private mutating func reportProgress(at offset: Int64) {
        guard let progress, file.size > 0 else { return }
        let fraction = min(1, Double(offset) / Double(file.size))
        guard fraction - reportedProgress >= 0.005 else { return }
        reportedProgress = fraction
        progress(fraction)
    }

    private mutating func checkCancellation(force: Bool) throws {
        blocksSinceCancellationCheck += 1
        if force || blocksSinceCancellationCheck >= 4096 {
            blocksSinceCancellationCheck = 0
            try Task.checkCancellation()
        }
    }
}

/// A block whose declared size runs past the bytes on disk.
private struct BlockTruncated: Error {}
