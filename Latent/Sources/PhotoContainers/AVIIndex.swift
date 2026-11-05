import Foundation

/// Reads an AVI file into the Matroska track model, the way mkvmerge carries
/// AVI streams: video as `V_MS/VFW/FOURCC` with the BITMAPINFOHEADER as
/// CodecPrivate, audio under its native Matroska codec ID where one exists
/// (MPEG audio, AC-3, AAC, PCM) and as `A_MS/ACM` with the WAVEFORMATEX
/// otherwise. Timestamps are nanoseconds (TimestampScale 1).
///
/// AVI has no timestamps. Video chunk n plays n frame durations after the
/// stream starts, in decode order (an empty chunk is a dropped frame), and
/// audio is one continuous stream measured in bytes, or in packets when it
/// is variable-bitrate. Chunk positions come from the OpenDML index when the
/// file has one (required past the first gigabyte), else from the legacy
/// `idx1`, else from a scan of the movie data: a recording that stopped
/// before its index was written still plays.
public enum AVIIndex {
    /// Indexes `url`. With `limit` (seconds), stops reading video half a
    /// second past it, and keeps audio to a second past the last frame.
    /// `progress` and cancellation work as in `MatroskaIndex.read`.
    public static func read(url: URL, limit: Double? = nil, progress: ((Double) -> Void)? = nil) throws -> MatroskaIndex {
        let file = try WindowedFile(url: url)
        var reader = AVIReader(file: file, limit: limit, progress: progress)
        return try reader.run()
    }
}

/// Four ASCII characters in reading order, so `FourCC("RIFF")` compares
/// against bytes as they appear in the file.
struct FourCC: Hashable, CustomStringConvertible {
    let raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init(_ text: StaticString) {
        precondition(text.utf8CodeUnitCount == 4)
        let p = text.utf8Start
        raw = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
    }

    /// From a little-endian `DWORD` holding the characters (biCompression).
    init(littleEndian value: UInt32) { raw = value.byteSwapped }

    var bytes: [UInt8] { [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)] }

    var description: String {
        String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    /// The stream number of a movie chunk ID such as `01wb`, or nil.
    var streamNumber: Int? {
        let b = bytes
        guard (0x30...0x39).contains(b[0]), (0x30...0x39).contains(b[1]) else { return nil }
        return Int(b[0] - 0x30) * 10 + Int(b[1] - 0x30)
    }

    var isIndexChunk: Bool { bytes[0] == UInt8(ascii: "i") && bytes[1] == UInt8(ascii: "x") }
}

extension WindowedFile {
    func le16(_ offset: Int64) throws -> UInt16? {
        guard try ensure(offset, 2) else { return nil }
        return UInt16(byte(offset)) | UInt16(byte(offset + 1)) << 8
    }

    func le32(_ offset: Int64) throws -> UInt32? {
        guard try ensure(offset, 4) else { return nil }
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = value << 8 | UInt32(byte(offset + Int64(i))) }
        return value
    }

    func fourCC(_ offset: Int64) throws -> FourCC? {
        guard try ensure(offset, 4) else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(byte(offset + Int64(i))) }
        return FourCC(raw: value)
    }
}

/// Little-endian reads from an in-memory structure (an index, a header).
extension Data {
    func le16(_ at: Int) -> UInt16 {
        guard at + 2 <= count else { return 0 }
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le64(_ at: Int) -> UInt64 {
        UInt64(le32(at)) | UInt64(le32(at + 4)) << 32
    }

    func fourCC(_ at: Int) -> FourCC {
        guard at + 4 <= count else { return FourCC(raw: 0) }
        let i = startIndex + at
        return FourCC(raw: UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]))
    }
}

/// The WAVEFORMATEX fields Latent reads, from an AVI `strf` or a Matroska
/// `A_MS/ACM` CodecPrivate.
struct WaveFormat {
    static let pcm: UInt16 = 0x0001
    static let msADPCM: UInt16 = 0x0002
    static let float: UInt16 = 0x0003
    static let aLaw: UInt16 = 0x0006
    static let muLaw: UInt16 = 0x0007
    static let imaADPCM: UInt16 = 0x0011
    static let gsm610: UInt16 = 0x0031
    static let mpeg: UInt16 = 0x0050
    static let mp3: UInt16 = 0x0055
    static let aac: UInt16 = 0x00FF
    static let ac3: UInt16 = 0x2000
    static let dts: UInt16 = 0x2001
    static let extensible: UInt16 = 0xFFFE

    let tag: UInt16
    let channels: Int
    let sampleRate: Int
    let averageBytesPerSecond: Int
    let blockAlign: Int
    let bitsPerSample: Int
    /// Bytes after `cbSize`.
    let extra: Data

    init?(_ data: Data) {
        guard data.count >= 14 else { return nil }
        var tag = data.le16(0)
        channels = Int(data.le16(2))
        sampleRate = Int(data.le32(4))
        averageBytesPerSecond = Int(data.le32(8))
        blockAlign = Int(data.le16(12))
        bitsPerSample = data.count >= 16 ? Int(data.le16(14)) : 0
        let declared = data.count >= 18 ? Int(data.le16(16)) : 0
        extra = data.count > 18 ? Data(data.dropFirst(18).prefix(declared)) : Data()
        // WAVE_FORMAT_EXTENSIBLE: the real tag opens the SubFormat GUID.
        if tag == Self.extensible, extra.count >= 8 { tag = extra.le16(6) }
        self.tag = tag
    }

    /// Samples per block of a block-based codec (ADPCM, GSM), or nil.
    var samplesPerBlock: Int? {
        switch tag {
        case Self.imaADPCM:
            if extra.count >= 2, extra.le16(0) > 0 { return Int(extra.le16(0)) }
            guard channels > 0, blockAlign > 4 * channels else { return nil }
            return (blockAlign - 4 * channels) * 8 / (4 * channels) + 1
        case Self.msADPCM:
            if extra.count >= 2, extra.le16(0) > 0 { return Int(extra.le16(0)) }
            guard channels > 0, blockAlign > 7 * channels else { return nil }
            return (blockAlign - 7 * channels) * 8 / (4 * channels) + 2
        case Self.gsm610:
            return 320
        default:
            return nil
        }
    }
}

/// The BITMAPINFOHEADER fields Latent reads.
struct BitmapInfo {
    let width: Int
    let height: Int
    let compression: FourCC
    let bitCount: Int
    /// Codec configuration after the 40-byte header (an MPEG-4 VOL, an avcC).
    let extra: Data

    init?(_ data: Data) {
        guard data.count >= 40 else { return nil }
        let headerSize = max(40, Int(data.le32(0)))
        width = Int(Int32(bitPattern: data.le32(4)))
        height = Int(Int32(bitPattern: data.le32(8)))
        bitCount = Int(data.le16(14))
        compression = FourCC(littleEndian: data.le32(16))
        extra = data.count > headerSize ? Data(data.dropFirst(headerSize)) : Data()
    }
}

private struct AVIReader {
    struct Chunk {
        var offset: Int64
        var size: UInt32
        var isKeyframe: Bool
        var prefix: UInt64 = 0
    }

    struct Stream {
        var type = FourCC(raw: 0)
        var handler = FourCC(raw: 0)
        var flags: UInt32 = 0
        var scale: UInt32 = 0
        var rate: UInt32 = 0
        var start: UInt32 = 0
        var sampleSize: UInt32 = 0
        var format = Data()
        var name: String?
        /// OpenDML super index: where each standard index chunk lives.
        var superIndex: [Int64] = []
        var chunks: [Chunk] = []
    }

    struct MovieList {
        let fourCCOffset: Int64
        let start: Int64
        let end: Int64
    }

    let file: WindowedFile
    let limit: Double?
    let progress: ((Double) -> Void)?
    var streams: [Stream] = []
    var movieLists: [MovieList] = []
    var legacyIndex: (offset: Int64, size: Int64)?
    var microsecondsPerFrame: UInt32 = 0
    var frameSize = (width: 0, height: 0)
    var isComplete = true
    var reportedProgress = 0.0

    init(file: WindowedFile, limit: Double?, progress: ((Double) -> Void)?) {
        self.file = file
        self.limit = limit
        self.progress = progress
    }

    mutating func run() throws -> MatroskaIndex {
        guard let riff = try file.fourCC(0), riff == FourCC("RIFF"),
              let type = try file.fourCC(8), type == FourCC("AVI ") else {
            throw ContainerError.unrecognized
        }
        // The first RIFF holds the headers; OpenDML files continue in
        // further `RIFF AVIX` chunks, each with its own movie list.
        var position: Int64 = 0
        while position + 12 <= file.size {
            guard let id = try file.fourCC(position), id == FourCC("RIFF"),
                  let declared = try file.le32(position + 4), let form = try file.fourCC(position + 8) else { break }
            let end = riffEnd(position: position, declared: declared)
            if form == FourCC("AVI ") || form == FourCC("AVIX") {
                try readChildren(of: position + 12, end: end, isFirst: form == FourCC("AVI "))
            }
            position = end + (end & 1)
        }
        guard streams.contains(where: { $0.type == FourCC("vids") || $0.type == FourCC("auds") || $0.type == FourCC("iavs") }) else {
            throw ContainerError.noPlayableTracks([])
        }
        guard !movieLists.isEmpty else { throw ContainerError.noMovieData }

        try Task.checkCancellation()
        if streams.contains(where: { !$0.superIndex.isEmpty }) {
            try readOpenDMLIndexes()
        } else if let legacyIndex, try readLegacyIndex(at: legacyIndex.offset, size: legacyIndex.size) {
            // idx1 covers only the first RIFF; later ones have to be walked.
            for list in movieLists.dropFirst() { try scan(list) }
        } else {
            for list in movieLists { try scan(list) }
        }
        progress?(1)
        return try makeIndex()
    }

    /// Where a RIFF chunk ends. A writer that never finished leaves a size of
    /// zero or one past the end of the file.
    private mutating func riffEnd(position: Int64, declared: UInt32) -> Int64 {
        let end = position + 8 + Int64(declared)
        if declared == 0 || end > file.size {
            if declared != 0 { isComplete = false }
            return file.size
        }
        return end
    }

    // MARK: Headers

    private mutating func readChildren(of start: Int64, end: Int64, isFirst: Bool) throws {
        var position = start
        while position + 8 <= end {
            guard let id = try file.fourCC(position), let size = try file.le32(position + 4) else { break }
            let dataStart = position + 8
            var chunkEnd = dataStart + Int64(size)
            if chunkEnd > end {
                isComplete = false
                chunkEnd = end
            }
            if id == FourCC("LIST"), let listType = try file.fourCC(dataStart) {
                switch listType {
                case FourCC("hdrl") where isFirst:
                    try readHeaderList(from: dataStart + 4, end: chunkEnd)
                case FourCC("movi"):
                    // A live recording leaves the movie list's size at zero.
                    let listEnd = size == 0 ? end : chunkEnd
                    movieLists.append(MovieList(fourCCOffset: dataStart, start: dataStart + 4, end: listEnd))
                    if size == 0 { return }
                default:
                    break
                }
            } else if id == FourCC("idx1"), isFirst {
                legacyIndex = (dataStart, chunkEnd - dataStart)
            }
            position = chunkEnd + (chunkEnd & 1)
        }
    }

    private mutating func readHeaderList(from start: Int64, end: Int64) throws {
        var position = start
        while position + 8 <= end {
            guard let id = try file.fourCC(position), let size = try file.le32(position + 4) else { return }
            let dataStart = position + 8
            let chunkEnd = min(dataStart + Int64(size), end)
            if id == FourCC("avih") {
                let header = try file.data(at: dataStart, count: Int(min(size, 64)))
                microsecondsPerFrame = header.le32(0)
                frameSize = (Int(header.le32(32)), Int(header.le32(36)))
            } else if id == FourCC("LIST"), try file.fourCC(dataStart) == FourCC("strl") {
                streams.append(try readStream(from: dataStart + 4, end: chunkEnd))
            }
            position = chunkEnd + (chunkEnd & 1)
        }
    }

    private func readStream(from start: Int64, end: Int64) throws -> Stream {
        var stream = Stream()
        var position = start
        while position + 8 <= end {
            guard let id = try file.fourCC(position), let size = try file.le32(position + 4) else { break }
            let dataStart = position + 8
            let chunkEnd = min(dataStart + Int64(size), end)
            let length = Int(chunkEnd - dataStart)
            switch id {
            case FourCC("strh"):
                let header = try file.data(at: dataStart, count: min(length, 64))
                stream.type = header.fourCC(0)
                stream.handler = header.fourCC(4)
                stream.flags = header.le32(8)
                stream.scale = header.le32(20)
                stream.rate = header.le32(24)
                stream.start = header.le32(28)
                stream.sampleSize = header.le32(44)
            case FourCC("strf"):
                stream.format = try file.data(at: dataStart, count: min(length, 1 << 20))
            case FourCC("strn"):
                var name = try file.data(at: dataStart, count: min(length, 256))
                while let last = name.last, last == 0 { name.removeLast() }
                stream.name = String(decoding: name, as: UTF8.self)
            case FourCC("indx"):
                let index = try file.data(at: dataStart, count: min(length, 1 << 20))
                // AVI_INDEX_OF_INDEXES: 24-byte header, 16-byte entries.
                if index.count >= 24, index[index.startIndex + 3] == 0x00, index.le16(0) == 4 {
                    let count = Int(index.le32(4))
                    for i in 0..<count where 24 + 16 * i + 16 <= index.count {
                        let offset = Int64(index.le64(24 + 16 * i))
                        if offset > 0 { stream.superIndex.append(offset) }
                    }
                }
            default:
                break
            }
            position = chunkEnd + (chunkEnd & 1)
        }
        return stream
    }

    // MARK: Indexes

    private mutating func readOpenDMLIndexes() throws {
        let total = max(1, streams.reduce(0) { $0 + $1.superIndex.count })
        var done = 0
        for s in streams.indices {
            for offset in streams[s].superIndex {
                try Task.checkCancellation()
                done += 1
                report(Double(done) / Double(total))
                guard offset + 32 <= file.size, let size = try file.le32(offset + 4), let id = try file.fourCC(offset),
                      id.isIndexChunk || id == FourCC("indx") else {
                    isComplete = false
                    continue
                }
                let body = try file.data(at: offset + 8, count: Int(min(Int64(size), file.size - offset - 8)))
                // AVI_INDEX_OF_CHUNKS: 24-byte header, then 2 (or, for
                // field indexes, 3) DWORDs per chunk.
                guard body.count >= 24, body[body.startIndex + 3] == 0x01 else { continue }
                let longs = max(2, Int(body.le16(0)))
                let count = Int(body.le32(4))
                let base = Int64(body.le64(12))
                for i in 0..<count {
                    let at = 24 + 4 * longs * i
                    guard at + 8 <= body.count else {
                        isComplete = false
                        break
                    }
                    let raw = body.le32(at + 4)
                    let chunk = Chunk(offset: base + Int64(body.le32(at)), size: raw & 0x7FFF_FFFF,
                                      isKeyframe: raw & 0x8000_0000 == 0)
                    guard append(chunk, to: s) else { break }
                }
            }
        }
    }

    /// Reads `idx1`. Returns false when it cannot be used (no entries, or
    /// offsets that match no chunk), so the movie list is scanned instead.
    private mutating func readLegacyIndex(at offset: Int64, size: Int64) throws -> Bool {
        let body = try file.data(at: offset, count: Int(min(size, file.size - offset)))
        let count = body.count / 16
        guard count > 0, let movie = movieLists.first else { return false }

        // Offsets are relative to the `movi` FourCC in most files and
        // absolute in some; the first stream entry tells which.
        guard let first = (0..<count).first(where: { body.fourCC(16 * $0).streamNumber != nil }) else { return false }
        let firstID = body.fourCC(16 * first)
        let firstOffset = Int64(body.le32(16 * first + 8))
        var base: Int64?
        for candidate in [movie.fourCCOffset, 0, movie.start] where candidate + firstOffset + 4 <= file.size {
            if try file.fourCC(candidate + firstOffset) == firstID {
                base = candidate
                break
            }
        }
        guard let base else { return false }

        for i in 0..<count {
            if i & 0x3FFF == 0 {
                try Task.checkCancellation()
                report(Double(i) / Double(count))
            }
            let id = body.fourCC(16 * i)
            guard let number = id.streamNumber, number < streams.count else { continue }
            let chunk = Chunk(offset: base + Int64(body.le32(16 * i + 8)) + 8, size: body.le32(16 * i + 12),
                              isKeyframe: body.le32(16 * i + 4) & 0x10 != 0)
            guard append(chunk, to: number) else { break }
        }
        return streams.contains { !$0.chunks.isEmpty }
    }

    /// Walks a movie list chunk by chunk: the fallback for a file without a
    /// usable index. Keyframes are unknown here and refined per codec later.
    private mutating func scan(_ list: MovieList) throws {
        var position = list.start
        var walked = 0
        while position + 8 <= list.end {
            walked += 1
            if walked & 0xFFF == 0 {
                try Task.checkCancellation()
                report(Double(position) / Double(max(1, file.size)))
            }
            guard let id = try file.fourCC(position), let size = try file.le32(position + 4) else { break }
            if id == FourCC("LIST") {
                // `rec ` groups interleaved chunks; its children are ordinary.
                if try file.fourCC(position + 8) == FourCC("rec ") {
                    position += 12
                    continue
                }
            } else if let number = id.streamNumber, number < streams.count {
                let dataStart = position + 8
                guard dataStart + Int64(size) <= list.end else {
                    isComplete = false
                    return
                }
                var chunk = Chunk(offset: dataStart, size: size, isKeyframe: true)
                if streams[number].type != FourCC("auds"), size > 0 {
                    chunk.prefix = try prefix(at: dataStart, size: size)
                }
                guard append(chunk, to: number) else { return }
            } else if !id.isIndexChunk, !isPlausible(id) {
                // Not a chunk header: the data is damaged from here on.
                isComplete = false
                return
            }
            let end = position + 8 + Int64(size)
            position = end + (end & 1)
        }
    }

    /// Adds a chunk unless it lies past the end of the file or, for video,
    /// past `limit`. Returns false when reading should stop: chunks are in
    /// file order, which is time order, so nothing later is needed.
    private mutating func append(_ chunk: Chunk, to stream: Int) -> Bool {
        guard chunk.offset + Int64(chunk.size) <= file.size else {
            isComplete = false
            return false
        }
        if let limit, streams[stream].type == FourCC("vids") || streams[stream].type == FourCC("iavs") {
            let seconds = Double(streams[stream].chunks.count) * frameDuration(streams[stream]) / 1_000_000_000
            if seconds > limit + 0.5 {
                isComplete = false
                return false
            }
        }
        streams[stream].chunks.append(chunk)
        return true
    }

    private func isPlausible(_ id: FourCC) -> Bool {
        id.bytes.allSatisfy { (0x20...0x7E).contains($0) }
    }

    private func prefix(at offset: Int64, size: UInt32) throws -> UInt64 {
        let data = try file.data(at: offset, count: Int(min(size, 8)))
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(i < data.count ? data[data.startIndex + i] : 0) }
        return value
    }

    private mutating func report(_ fraction: Double) {
        guard let progress, fraction - reportedProgress >= 0.005 else { return }
        reportedProgress = fraction
        progress(min(1, fraction))
    }

    // MARK: Tracks

    /// Nanoseconds per video frame.
    private func frameDuration(_ stream: Stream) -> Double {
        if stream.scale > 0, stream.rate > 0 { return Double(stream.scale) * 1e9 / Double(stream.rate) }
        if microsecondsPerFrame > 0 { return Double(microsecondsPerFrame) * 1000 }
        return 1e9 / 30
    }

    private func makeIndex() throws -> MatroskaIndex {
        var index = MatroskaIndex()
        index.docType = "avi"
        index.timestampScale = 1
        index.isComplete = isComplete
        var sawVideo = false
        var sawAudio = false
        for (number, stream) in streams.enumerated() {
            var track: MatroskaTrack
            switch stream.type {
            case FourCC("vids"), FourCC("iavs"):
                track = try videoTrack(stream)
                track.isDefault = !sawVideo
                sawVideo = true
                if stream.type == FourCC("iavs") {
                    // Type-1 DV: one stream whose frames carry the sound too.
                    var sound = MatroskaTrack()
                    sound.number = UInt64(streams.count + number + 1)
                    sound.kind = .audio
                    sound.codecID = "A_DV/EMBEDDED"
                    sound.language = nil
                    index.tracks.append(sound)
                }
            case FourCC("auds"):
                track = audioTrack(stream)
                track.isDefault = !sawAudio
                sawAudio = true
            default:
                continue
            }
            track.number = UInt64(number + 1)
            track.name = stream.name
            track.language = nil
            track.isEnabled = stream.flags & 0x1 == 0
            index.tracks.append(track)
        }
        // A limited read keeps a second of sound past the last frame; an
        // audio-only file keeps `limit` seconds of it.
        if let limit {
            let videoEnd = index.tracks.filter { $0.kind == .video }.compactMap { $0.frames.last?.timestamp }.max()
            for t in index.tracks.indices where index.tracks[t].kind == .audio {
                guard let first = index.tracks[t].frames.first?.timestamp else { continue }
                let cutoff = (videoEnd ?? first + Int64(limit * 1e9)) + 1_000_000_000
                if let last = index.tracks[t].frames.lastIndex(where: { $0.timestamp <= cutoff }),
                   last + 1 < index.tracks[t].frames.count {
                    index.tracks[t].frames.removeSubrange((last + 1)...)
                    index.isComplete = false
                }
            }
        }
        return index
    }

    private func videoTrack(_ stream: Stream) throws -> MatroskaTrack {
        var track = MatroskaTrack()
        track.kind = .video
        track.codecID = "V_MS/VFW/FOURCC"
        track.timestampsInDecodeOrder = true
        var format = stream.format
        if stream.type == FourCC("iavs") || BitmapInfo(format) == nil {
            // DVINFO, or no format at all: describe the frames from the
            // stream handler and the main header.
            format = Self.bitmapInfo(width: frameSize.width, height: frameSize.height, compression: stream.handler)
        }
        track.codecPrivate = format
        if let info = BitmapInfo(format) {
            track.pixelWidth = abs(info.width)
            track.pixelHeight = abs(info.height)
        }
        let duration = frameDuration(stream)
        track.defaultDuration = UInt64(duration.rounded())
        let start = Double(stream.start)
        var keyframes = 0
        for (n, chunk) in stream.chunks.enumerated() where chunk.size > 0 {
            if chunk.isKeyframe { keyframes += 1 }
            track.frames.append(MatroskaFrame(
                offset: chunk.offset, size: Int32(clamping: chunk.size),
                timestamp: Int64(((start + Double(n)) * duration).rounded()),
                blockDuration: -1, laceIndex: 0, laceCount: 1,
                isKeyframe: chunk.isKeyframe, prefix: chunk.prefix
            ))
        }
        // An index that marks nothing as a keyframe (or a scan, which marks
        // everything) says nothing; MPEG-4 frames announce their own type,
        // in headers a scan has already read.
        if keyframes == 0 || stream.chunks.allSatisfy(\.isKeyframe) {
            if let info = BitmapInfo(format), MatroskaCodecs.VFWCodec(info.compression) == .mpeg4 {
                for i in track.frames.indices where track.frames[i].prefix == 0 {
                    if i & 0xFFF == 0 { try Task.checkCancellation() }
                    track.frames[i].prefix = try prefix(at: track.frames[i].offset, size: UInt32(track.frames[i].size))
                }
            }
            for i in track.frames.indices {
                if let isKeyframe = Self.mpeg4IsKeyframe(prefix: track.frames[i].prefix) {
                    track.frames[i].isKeyframe = isKeyframe
                } else if keyframes == 0 {
                    track.frames[i].isKeyframe = true
                }
            }
        }
        return track
    }

    /// For an MPEG-4 Part 2 frame: true when it opens with stream headers or
    /// an I-VOP, false for any other VOP, nil when it is not MPEG-4 at all.
    private static func mpeg4IsKeyframe(prefix: UInt64) -> Bool? {
        guard prefix >> 40 == 0x000001 else { return nil }
        let code = UInt8(prefix >> 32 & 0xFF)
        if code == 0xB6 { return prefix >> 30 & 0b11 == 0 }
        return code == 0xB0 || code == 0xB3 || code <= 0x2F
    }

    private func audioTrack(_ stream: Stream) -> MatroskaTrack {
        var track = MatroskaTrack()
        track.kind = .audio
        guard let wave = WaveFormat(stream.format) else {
            track.codecID = "A_MS/ACM"
            return track
        }
        track.samplingFrequency = Double(wave.sampleRate)
        track.channels = max(1, wave.channels)
        if wave.bitsPerSample > 0 { track.bitDepth = wave.bitsPerSample }

        let isPCM = wave.tag == WaveFormat.pcm || wave.tag == WaveFormat.float
        switch wave.tag {
        case WaveFormat.pcm: track.codecID = "A_PCM/INT/LIT"
        case WaveFormat.float: track.codecID = "A_PCM/FLOAT/IEEE"
        case WaveFormat.mp3: track.codecID = "A_MPEG/L3"
        case WaveFormat.mpeg:
            // MPEG1WAVEFORMAT.fwHeadLayer: 1 = Layer I, 2 = II, 4 = III.
            let layer = wave.extra.count >= 2 ? wave.extra.le16(0) : 2
            track.codecID = layer == 1 ? "A_MPEG/L1" : layer == 4 ? "A_MPEG/L3" : "A_MPEG/L2"
        case WaveFormat.ac3: track.codecID = "A_AC3"
        case WaveFormat.dts: track.codecID = "A_DTS"
        case WaveFormat.aac, 0x706D, 0x4143:
            track.codecID = "A_AAC"
            track.codecPrivate = wave.extra
            // Without a decoder configuration the chunks hold ADTS frames,
            // headers and all.
            if wave.extra.isEmpty, firstPacketLengths(stream, parser: ADTS.frameLength).first != nil {
                track.needsRepacketizing = true
            }
        default:
            track.codecID = "A_MS/ACM"
            track.codecPrivate = stream.format
        }

        // Variable-bitrate audio stores one packet per chunk, each lasting
        // `scale / rate` seconds. Everything else is a byte stream whose
        // chunk boundaries need not fall between packets.
        let isVBR = stream.sampleSize == 0 && !isPCM
        let parser: (([UInt8], Int) -> Int?)? = switch track.codecID {
        case "A_MPEG/L1", "A_MPEG/L2", "A_MPEG/L3": MPEGAudio.frameLength
        case "A_AC3": AC3.frameLength
        default: nil
        }
        if let parser {
            // Some muxers pack several variable-bitrate frames into a chunk.
            track.needsRepacketizing = !isVBR || zip(stream.chunks.lazy.filter { $0.size > 0 },
                                                     firstPacketLengths(stream, parser: parser))
                .contains { chunk, length in Int(chunk.size) > length }
        }

        let rate = Double(stream.rate > 0 ? stream.rate : UInt32(max(1, wave.averageBytesPerSecond)))
        let scale = Double(stream.scale > 0 ? stream.scale : UInt32(max(1, wave.blockAlign)))
        let bytesPerUnit = Double(stream.sampleSize > 0 ? stream.sampleSize : UInt32(max(1, wave.blockAlign)))
        let start = Double(stream.start)
        var bytesBefore: Double = 0
        for (n, chunk) in stream.chunks.enumerated() {
            let units = isVBR ? Double(n) : bytesBefore / bytesPerUnit
            bytesBefore += Double(chunk.size)
            guard chunk.size > 0 else { continue }
            track.frames.append(MatroskaFrame(
                offset: chunk.offset, size: Int32(clamping: chunk.size),
                timestamp: Int64(((start + units) * scale * 1e9 / rate).rounded()),
                blockDuration: -1, laceIndex: 0, laceCount: 1, isKeyframe: true, prefix: 0
            ))
        }
        return track
    }

    /// The packet lengths that the first few non-empty chunks of an audio
    /// stream open with, as far as `parser` recognizes them.
    private func firstPacketLengths(_ stream: Stream, parser: ([UInt8], Int) -> Int?) -> [Int] {
        var lengths: [Int] = []
        for chunk in stream.chunks.lazy.filter({ $0.size > 0 }).prefix(8) {
            guard let header = try? file.data(at: chunk.offset, count: Int(min(chunk.size, 8))),
                  let length = parser([UInt8](header), 0) else { break }
            lengths.append(length)
        }
        return lengths
    }

    /// A BITMAPINFOHEADER for streams that do not carry one (type-1 DV).
    static func bitmapInfo(width: Int, height: Int, compression: FourCC) -> Data {
        var data = Data(count: 40)
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8(value >> (8 * UInt32(i)) & 0xFF) }
        }
        put(40, at: 0)
        put(UInt32(truncatingIfNeeded: width), at: 4)
        put(UInt32(truncatingIfNeeded: height), at: 8)
        data[12] = 1
        data[14] = 24
        put(compression.raw.byteSwapped, at: 16)
        return data
    }
}
