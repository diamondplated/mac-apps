import Foundation
import Darwin

/// Frames rewritten into a form AVFoundation can read, for the few streams
/// whose bytes on disk it cannot take by reference. Deleted when the last
/// movie that reads it goes away; a directory per process lets a later
/// launch clear what a crash left behind.
final class ScratchFile {
    let url: URL
    private let handle: FileHandle
    private var pending = Data()
    private(set) var length: Int64 = 0

    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Latent Scratch", isDirectory: true)

    private static let processDirectory: URL = {
        sweepAbandoned()
        return directory.appendingPathComponent(String(getpid()), isDirectory: true)
    }()

    init() throws {
        let folder = Self.processDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(UUID().uuidString + ".bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Appends `data` and returns the offset it was written at.
    func append(_ data: Data) throws -> Int64 {
        let offset = length
        pending.append(data)
        length += Int64(data.count)
        if pending.count >= 1 << 20 { try flush() }
        return offset
    }

    func finish() throws {
        try flush()
        try handle.close()
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Why `bytes` can't be written now, or nil when there is room. The
    /// volume keeps some space spare: the copy lasts as long as the movie.
    static func shortage(for bytes: Int64, writing what: String) -> String? {
        guard let free = availableCapacity(), free < bytes + 64 << 20 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "there isn't enough free disk space to \(what) (it needs \(size))"
    }

    /// Bytes free on the scratch volume, when the system will say.
    static func availableCapacity() -> Int64? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Removes the folders of processes that are no longer running.
    private static func sweepAbandoned() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let pid = pid_t(folder.lastPathComponent), pid != getpid() else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

/// Readies tracks whose frames AVFoundation cannot read where they lie:
///
/// - H.264 from an AVI is an Annex B byte stream (start codes, parameter
///   sets in band, frames in decode order with no presentation times). It is
///   rewritten with length prefixes into a scratch file, given an `avcC`,
///   and its presentation times are recovered from each picture's order
///   count.
/// - Constant-bitrate audio in an AVI is one byte stream cut into chunks
///   wherever the muxer liked. MPEG audio and AC-3 are re-cut on frame
///   headers, and ADPCM and GSM on their fixed block size, so every sample
///   is one codec packet. So are variable-bitrate chunks holding several
///   MPEG audio frames, and ADTS-framed AAC, whose headers are dropped.
///   Packets stay references into the original file when every one lies
///   inside a single chunk; otherwise the stream is copied into a scratch
///   file.
struct TrackPreparation {
    enum Outcome {
        case ready(MatroskaTrack)
        case unsupported(String)
    }

    private let source: URL
    private let reader: FileHandle?
    /// Every scratch file written; the movie keeps them alive.
    private(set) var scratchFiles: [ScratchFile] = []

    init(source: URL) {
        self.source = source
        reader = try? FileHandle(forReadingFrom: source)
    }

    func close() {
        try? reader?.close()
    }

    /// Bytes `prepare` will read for `track`, for progress.
    static func work(for track: MatroskaTrack) -> Int64 {
        let bytes = track.frames.reduce(Int64(0)) { $0 + Int64($1.size) }
        switch plan(for: track) {
        case .h264, .repacketize: return bytes
        case .splitBlocks(let blockAlign, _):
            return track.frames.allSatisfy { Int($0.size) % blockAlign == 0 } ? 0 : bytes
        case .none: return 0
        }
    }

    private enum Plan {
        case none
        case h264(BitmapInfo)
        case repacketize(PacketParser)
        case splitBlocks(blockAlign: Int, samplesPerBlock: Int)
    }

    private static func plan(for track: MatroskaTrack) -> Plan {
        if track.kind == .video, track.codecID == "V_MS/VFW/FOURCC",
           let info = BitmapInfo(track.codecPrivate), MatroskaCodecs.VFWCodec(info.compression) == .h264 {
            return .h264(info)
        }
        guard track.kind == .audio else { return .none }
        if track.needsRepacketizing {
            switch track.codecID {
            case "A_MPEG/L1", "A_MPEG/L2", "A_MPEG/L3": return .repacketize(.mpegAudio)
            case "A_AC3": return .repacketize(.ac3)
            case "A_AAC": return .repacketize(.adts)
            default: return .none
            }
        }
        if track.codecID == "A_MS/ACM", let wave = WaveFormat(track.codecPrivate),
           [WaveFormat.imaADPCM, WaveFormat.msADPCM, WaveFormat.gsm610].contains(wave.tag),
           wave.blockAlign > 0, let samples = wave.samplesPerBlock, samples > 0 {
            return .splitBlocks(blockAlign: wave.blockAlign, samplesPerBlock: samples)
        }
        return .none
    }

    /// `progress` receives bytes read so far for this track.
    mutating func prepare(_ track: MatroskaTrack, progress: (Int64) -> Void) throws -> Outcome {
        guard !track.frames.isEmpty else { return .ready(track) }
        switch Self.plan(for: track) {
        case .none:
            return .ready(track)
        case .h264(let info):
            return try convertH264(track, info: info, progress: progress)
        case .repacketize(let parser):
            return try repacketize(track, parser: parser, progress: progress)
        case .splitBlocks(let blockAlign, let samplesPerBlock):
            if track.frames.allSatisfy({ Int($0.size) % blockAlign == 0 }) {
                return .ready(splitAlignedBlocks(track, blockAlign: blockAlign, samplesPerBlock: samplesPerBlock))
            }
            return try repacketize(track, parser: .fixed(blockAlign), progress: progress)
        }
    }

    private func read(_ frame: MatroskaFrame) throws -> Data {
        guard let reader else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path]) }
        try reader.seek(toOffset: UInt64(frame.offset))
        return try reader.read(upToCount: Int(frame.size)) ?? Data()
    }

    // MARK: Audio packets

    /// Splits chunks that hold whole blocks into one frame per block, in
    /// place: nothing is copied.
    private func splitAlignedBlocks(_ track: MatroskaTrack, blockAlign: Int, samplesPerBlock: Int) -> MatroskaTrack {
        var split = track
        split.frames = []
        let blockNanoseconds = Double(samplesPerBlock) * 1e9 / max(1, track.samplingFrequency)
        for frame in track.frames {
            for block in 0..<(Int(frame.size) / blockAlign) {
                var piece = frame
                piece.offset = frame.offset + Int64(block * blockAlign)
                piece.size = Int32(blockAlign)
                piece.timestamp = frame.timestamp + Int64((Double(block) * blockNanoseconds).rounded())
                split.frames.append(piece)
            }
        }
        return split
    }

    enum PacketParser {
        case mpegAudio
        case ac3
        /// AAC behind ADTS headers, which the packet leaves out.
        case adts
        case fixed(Int)

        /// Bytes a packet header at `i` declares, or nil when `i` is not a
        /// packet header. `bytes` holds at least `headerSize` bytes from `i`.
        func length(_ bytes: [UInt8], at i: Int) -> Int? {
            switch self {
            case .mpegAudio: MPEGAudio.frameLength(bytes, at: i)
            case .ac3: AC3.frameLength(bytes, at: i)
            case .adts: ADTS.frameLength(bytes, at: i)
            case .fixed(let size): size
            }
        }

        /// Leading bytes of a packet that are framing, not codec data.
        func framing(_ bytes: [UInt8], at i: Int) -> Int {
            if case .adts = self { return ADTS.headerLength(bytes, at: i) }
            return 0
        }

        var headerSize: Int {
            switch self {
            case .mpegAudio: 4
            case .ac3: 6
            case .adts: 7
            case .fixed: 0
            }
        }

        /// Whether a header must be followed by another one to count, which
        /// keeps a sync pattern inside audio data from being taken for one.
        var confirmsWithNext: Bool {
            if case .fixed = self { return false }
            return true
        }
    }

    /// Re-cuts a byte stream into codec packets. Each packet's timestamp is
    /// interpolated from the chunk it starts in, which AVI times by bytes.
    /// The first pass only finds the packets; the stream is copied in a
    /// second pass, and only when a packet straddles two chunks.
    private mutating func repacketize(_ track: MatroskaTrack, parser: PacketParser,
                                      progress: (Int64) -> Void) throws -> Outcome {
        let frames = track.frames
        var chunkStart: [Int64] = []
        var total: Int64 = 0
        for frame in frames {
            chunkStart.append(total)
            total += Int64(frame.size)
        }
        func nanosecondsPerByte(_ c: Int) -> Double {
            if c + 1 < frames.count, frames[c].size > 0 {
                return Double(frames[c + 1].timestamp - frames[c].timestamp) / Double(frames[c].size)
            }
            return c > 0 ? nanosecondsPerByte(c - 1) : 0
        }

        // The stream's bytes through a sliding window, chunk by chunk. Each
        // pass reports half of the track's work.
        var buffer: [UInt8] = []
        var bufferStart: Int64 = 0
        var loaded = 0
        var passBase: Int64 = 0
        func load(through end: Int64) throws -> Bool {
            while bufferStart + Int64(buffer.count) < end, loaded < frames.count {
                buffer.append(contentsOf: try read(frames[loaded]))
                loaded += 1
                if loaded & 0xFF == 0 {
                    try Task.checkCancellation()
                    progress(passBase + (bufferStart + Int64(buffer.count)) / 2)
                }
            }
            return bufferStart + Int64(buffer.count) >= end
        }
        func release(before position: Int64) {
            guard position - bufferStart >= 1 << 20 else { return }
            buffer.removeFirst(Int(min(position - bufferStart, Int64(buffer.count))))
            bufferStart = position
        }

        struct Packet {
            /// Codec data, framing excluded, in stream bytes.
            let start: Int64
            let end: Int64
            let chunk: Int
            let timestamp: Int64
            let prefix: UInt64
        }
        var packets: [Packet] = []
        var fitsChunks = true
        var configuration: Data?
        let header = Int64(parser.headerSize)
        var chunk = 0
        var position: Int64 = 0
        while try load(through: position + max(1, header)) {
            defer { release(before: position) }
            let i = Int(position - bufferStart)
            guard let length = parser.length(buffer, at: i), length > 0 else {
                position += 1
                continue
            }
            let end = position + Int64(length)
            if end > total { break }                          // a cut-off last packet
            if parser.confirmsWithNext, end + header <= total {
                guard try load(through: end + header),
                      parser.length(buffer, at: Int(end - bufferStart)) != nil else {
                    position += 1
                    continue
                }
            }
            _ = try load(through: end)

            while chunk + 1 < frames.count, chunkStart[chunk + 1] <= position { chunk += 1 }
            let into = position - chunkStart[chunk]
            let framing = parser.framing(buffer, at: i)
            if case .adts = parser, configuration == nil { configuration = ADTS.audioSpecificConfig(buffer, at: i) }
            packets.append(Packet(
                start: position + Int64(framing), end: end, chunk: chunk,
                timestamp: frames[chunk].timestamp + Int64((Double(into) * nanosecondsPerByte(chunk)).rounded()),
                prefix: Self.prefix(buffer[(i + framing)..<min(i + length, i + framing + 8)])
            ))
            if into + Int64(length) > Int64(frames[chunk].size) { fitsChunks = false }
            position = end
        }

        guard let last = packets.last, last.end > last.start else {
            return .unsupported("its \(track.kindName) track has no readable packets")
        }
        func frame(_ packet: Packet, at offset: Int64) -> MatroskaFrame {
            MatroskaFrame(offset: offset, size: Int32(packet.end - packet.start), timestamp: packet.timestamp,
                          blockDuration: -1, laceIndex: 0, laceCount: 1, isKeyframe: true, prefix: packet.prefix)
        }
        var ready = track
        ready.needsRepacketizing = false
        if let configuration { ready.codecPrivate = configuration }
        if fitsChunks {
            ready.frames = packets.map { frame($0, at: frames[$0.chunk].offset + $0.start - chunkStart[$0.chunk]) }
            progress(total)
            return .ready(ready)
        }

        let bytes = packets.reduce(Int64(0)) { $0 + $1.end - $1.start }
        if let reason = ScratchFile.shortage(for: bytes, writing: "re-cut its \(track.kindName)") {
            return .unsupported(reason)
        }
        let scratch = try ScratchFile()
        (buffer, bufferStart, loaded, passBase) = ([], 0, 0, total / 2)
        var copied: [MatroskaFrame] = []
        copied.reserveCapacity(packets.count)
        for packet in packets {
            guard try load(through: packet.end) else { break }
            let i = Int(packet.start - bufferStart)
            let offset = try scratch.append(Data(buffer[i..<(i + Int(packet.end - packet.start))]))
            copied.append(frame(packet, at: offset))
            release(before: packet.end)
        }
        progress(total)
        try scratch.finish()
        scratchFiles.append(scratch)
        ready.frames = copied
        ready.dataURL = scratch.url
        return .ready(ready)
    }

    private static func prefix(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 { value = value << 8 | UInt64(k < bytes.count ? bytes[bytes.startIndex + k] : 0) }
        return value
    }

    // MARK: H.264

    private mutating func convertH264(_ track: MatroskaTrack, info: BitmapInfo,
                                      progress: (Int64) -> Void) throws -> Outcome {
        let needed = track.frames.reduce(Int64(0)) { $0 + Int64($1.size) + 64 }
        if let reason = ScratchFile.shortage(for: needed, writing: "prepare its H.264 video") {
            return .unsupported(reason)
        }

        var sequences: [Int: H264.SequenceParameters] = [:]
        var pictures: [Int: H264.PictureParameters] = [:]
        var sequenceData: [Int: Data] = [:]
        var pictureData: [Int: Data] = [:]
        var setOrder: (sps: [Int], pps: [Int]) = ([], [])
        func remember(_ unit: Data) {
            switch unit.first.map({ $0 & 0x1F }) {
            case H264.sps:
                guard let sps = H264.SequenceParameters(unit), sequenceData[sps.id] == nil else { return }
                sequences[sps.id] = sps
                sequenceData[sps.id] = unit
                setOrder.sps.append(sps.id)
            case H264.pps:
                guard let pps = H264.PictureParameters(unit), pictureData[pps.id] == nil else { return }
                pictures[pps.id] = pps
                pictureData[pps.id] = unit
                setOrder.pps.append(pps.id)
            default:
                break
            }
        }
        var lengthSize: Int?
        if let record = H264.parseAVCC(info.extra) {
            record.sps.forEach(remember)
            record.pps.forEach(remember)
            lengthSize = record.lengthSize
        } else {
            // Some muxers store the parameter sets as an Annex B blob.
            H264.annexBUnits(info.extra).forEach(remember)
        }

        let scratch = try ScratchFile()
        var converted = track
        converted.frames = []
        var orders: [(period: Int, count: Int)?] = []
        var isIDR: [Bool] = []
        var counter = H264.OrderCounter()
        var period = 0
        var bytesRead: Int64 = 0

        for (n, frame) in track.frames.enumerated() {
            if n & 0xFF == 0 {
                try Task.checkCancellation()
                progress(bytesRead)
            }
            let data = try read(frame)
            bytesRead += Int64(frame.size)
            let units: [Data]
            if H264.startsWithStartCode(data) {
                units = H264.annexBUnits(data)
            } else if let lengthSize, let prefixed = H264.lengthPrefixedUnits(data, lengthSize: lengthSize) {
                units = prefixed
            } else {
                units = H264.annexBUnits(data)
            }
            var sample = Data()
            var order: (period: Int, count: Int)?
            var idr = false
            var sawSlice = false
            for unit in units {
                guard let type = unit.first.map({ $0 & 0x1F }) else { continue }
                remember(unit)
                if !sawSlice, type == H264.sliceIDR || type == H264.sliceNonIDR {
                    sawSlice = true
                    idr = type == H264.sliceIDR
                    if idr { period += 1 }
                    if let slice = H264.SliceHeader(unit, sps: sequences, pps: pictures),
                       let pps = pictures[slice.ppsID], let sps = sequences[pps.spsID],
                       let count = counter.count(slice, sps: sps) {
                        order = (period, count)
                    }
                }
                var length = UInt32(unit.count).bigEndian
                sample.append(Data(bytes: &length, count: 4))
                sample.append(unit)
            }
            // A chunk with no picture in it (parameter sets or delimiters
            // alone) is not a frame; its parameter sets are remembered.
            guard sawSlice else { continue }
            var rewritten = frame
            rewritten.offset = try scratch.append(sample)
            rewritten.size = Int32(clamping: sample.count)
            converted.frames.append(rewritten)
            orders.append(order)
            isIDR.append(idr)
        }
        progress(bytesRead)

        guard let firstSPS = setOrder.sps.first, sequenceData[firstSPS] != nil, !setOrder.pps.isEmpty,
              let avcC = H264.avcC(sps: setOrder.sps.compactMap { sequenceData[$0] },
                                   pps: setOrder.pps.compactMap { pictureData[$0] }) else {
            return .unsupported("its H.264 video has no parameter sets")
        }
        guard !converted.frames.isEmpty else { return .unsupported("its H.264 video is empty") }
        try scratch.finish()
        scratchFiles.append(scratch)

        // A scanned file marks every frame as a keyframe; the slices know.
        let flags = converted.frames.map(\.isKeyframe)
        if flags.allSatisfy({ $0 }) || !flags.contains(true), isIDR.contains(true) {
            for i in converted.frames.indices { converted.frames[i].isKeyframe = isIDR[i] }
        }

        // Presentation order: by order count within each IDR period. The
        // frame shown r-th takes the r-th decode slot, delayed by the
        // deepest reordering so that no frame shows before it decodes. This
        // is how ffmpeg times H.264 in AVI, so audio stays where it put it.
        if orders.allSatisfy({ $0 != nil }) {
            let keys = orders.map { $0! }
            let display = keys.indices.sorted { keys[$0].period != keys[$1].period
                ? keys[$0].period < keys[$1].period
                : keys[$0].count != keys[$1].count ? keys[$0].count < keys[$1].count : $0 < $1 }
            var rank = [Int](repeating: 0, count: keys.count)
            for (r, i) in display.enumerated() { rank[i] = r }
            let delay = max(0, rank.indices.map { $0 - rank[$0] }.max() ?? 0)
            let slots = converted.frames.map(\.timestamp)
            let frameDuration = track.defaultDuration.map(Int64.init)
                ?? (slots.count > 1 ? slots[1] - slots[0] : 33_333_333)
            for i in converted.frames.indices {
                converted.frames[i].timestamp = slots[rank[i]] + Int64(delay) * frameDuration
            }
        }

        converted.codecID = "V_MPEG4/ISO/AVC"
        converted.codecPrivate = avcC
        converted.dataURL = scratch.url
        converted.timestampsInDecodeOrder = false
        return .ready(converted)
    }
}

/// MPEG-1/2/2.5 audio frame headers (ISO/IEC 11172-3, 13818-3).
enum MPEGAudio {
    private static let bitrates: [[Int]] = [
        [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // MPEG-1 Layer I
        [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],    // MPEG-1 Layer II
        [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],     // MPEG-1 Layer III
        [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],    // MPEG-2 Layer I
        [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],         // MPEG-2 Layers II, III
    ]

    static func frameLength(_ b: [UInt8], at i: Int) -> Int? {
        guard i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int(b[i + 1] >> 3 & 3)      // 0: 2.5, 2: 2, 3: 1
        let layer = Int(b[i + 1] >> 1 & 3)        // 1: III, 2: II, 3: I
        let bitrateIndex = Int(b[i + 2] >> 4)
        let rateIndex = Int(b[i + 2] >> 2 & 3)
        guard version != 1, layer != 0, (1...14).contains(bitrateIndex), rateIndex != 3 else { return nil }
        let padding = Int(b[i + 2] >> 1 & 1)
        let rate = [44100, 48000, 32000][rateIndex] >> (version == 3 ? 0 : version == 2 ? 1 : 2)
        let table = version == 3 ? 3 - layer : (layer == 3 ? 3 : 4)
        let bitrate = bitrates[table][bitrateIndex - 1] * 1000
        switch layer {
        case 3: return (12 * bitrate / rate + padding) * 4
        case 1 where version != 3: return 72 * bitrate / rate + padding
        default: return 144 * bitrate / rate + padding
        }
    }
}

/// ADTS frame headers (ISO/IEC 14496-3, 1.A.2): AAC as some AVI muxers
/// store it, each packet behind a header that also stands in for the
/// decoder configuration.
enum ADTS {
    /// The whole frame, header included, when `i` starts an ADTS header
    /// with one raw data block.
    static func frameLength(_ b: [UInt8], at i: Int) -> Int? {
        guard i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        guard b[i + 2] >> 2 & 0x0F < 12, b[i + 6] & 0x03 == 0 else { return nil }
        let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
        return length > headerLength(b, at: i) ? length : nil
    }

    /// 7 bytes, or 9 when a CRC follows.
    static func headerLength(_ b: [UInt8], at i: Int) -> Int {
        b[i + 1] & 0x01 == 1 ? 7 : 9
    }

    /// The two-byte AudioSpecificConfig the header implies.
    static func audioSpecificConfig(_ b: [UInt8], at i: Int) -> Data {
        let objectType = b[i + 2] >> 6 + 1
        let rateIndex = b[i + 2] >> 2 & 0x0F
        let channels = (b[i + 2] & 0x01) << 2 | b[i + 3] >> 6
        return Data([objectType << 3 | rateIndex >> 1, (rateIndex & 1) << 7 | channels << 3])
    }
}

/// AC-3 sync frame headers (ATSC A/52).
enum AC3 {
    private static let kilobits = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

    static func frameLength(_ b: [UInt8], at i: Int) -> Int? {
        guard i + 6 <= b.count, b[i] == 0x0B, b[i + 1] == 0x77 else { return nil }
        let rateCode = Int(b[i + 4] >> 6)
        let sizeCode = Int(b[i + 4] & 0x3F)
        let bsid = Int(b[i + 5] >> 3)
        guard rateCode < 3, sizeCode < 38, bsid <= 10 else { return nil }
        let kbps = kilobits[sizeCode / 2]
        let words: Int
        switch rateCode {
        case 0: words = kbps * 2                                  // 48 kHz
        case 1: words = kbps * 1000 * 96 / 44100 + (sizeCode & 1) // 44.1 kHz
        default: words = kbps * 3                                 // 32 kHz
        }
        return words * 2
    }
}
