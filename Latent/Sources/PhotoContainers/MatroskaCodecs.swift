import Foundation
import CoreMedia
import CoreVideo
import AudioToolbox
import VideoToolbox

/// How a Matroska track's frames are handed to AVFoundation.
enum TrackMapping {
    case video(CMVideoFormatDescription)
    case audio(CMAudioFormatDescription, AudioPacketTiming, AudioStart)
    case unsupported(String)
}

/// How AVFoundation treats the first samples of an audio track, which
/// decides how much of Matroska's CodecDelay is still ours to trim. Each
/// case was measured against a click placed exactly on a video frame.
enum AudioStart {
    /// The decoder removes nothing on its own: trim all of CodecDelay.
    case exact
    /// The decoder already hides its own delay (AC-3, MPEG audio), which
    /// encoders count in CodecDelay. Only the remainder is trimmed, or the
    /// audio would play early by that delay.
    case decoderHides(Int64)
    /// AAC in a QuickTime movie that carries no `roll` sample groups (an
    /// in-memory movie cannot) is assumed to start with Apple's encoder
    /// priming, so the first `n` samples are never presented whatever the
    /// edit says. Trim only what CodecDelay exceeds that by; when it is
    /// shorter, start the track late instead so the first audible sample
    /// still lands on its Matroska timestamp.
    case movieHidesPriming(Int64)
}

/// How long each audio packet plays, in samples at the track's timescale.
/// Matroska block timestamps are rounded to the TimestampScale (usually a
/// millisecond), so laying 1024-sample AAC packets out on those timestamps
/// would leave sub-millisecond gaps and overlaps the audio renderer can hear.
enum AudioPacketTiming {
    /// Every packet decodes to the same number of samples.
    case fixed(Int64)
    /// Opus: read from each packet's TOC byte.
    case opus
    /// Uncompressed PCM: each block holds `size / bytesPerFrame` samples.
    case pcm(bytesPerFrame: Int)
    /// Unknown in advance: derived from timestamps, rounded to `granularity`.
    case fromTimestamps(granularity: Int64)
}

enum MatroskaCodecs {
    /// Codec IDs whose track media is a known decoder-less format; reported
    /// instead of silently dropped so the viewer can say why it is silent.
    private static let undecodableAudio: [String: String] = [
        "A_DTS": "DTS", "A_DTS/EXPRESS": "DTS Express", "A_DTS/LOSSLESS": "DTS-HD",
        "A_TRUEHD": "Dolby TrueHD", "A_MLP": "MLP", "A_VORBIS": "Vorbis",
        "A_REAL/COOK": "RealAudio", "A_REAL/SIPR": "RealAudio", "A_REAL/ATRC": "RealAudio",
        "A_TTA1": "TTA", "A_WAVPACK4": "WavPack", "A_QUICKTIME": "QuickTime audio",
    ]
    private static let undecodableVideo: [String: String] = [
        "V_VP8": "VP8", "V_THEORA": "Theora",
        "V_REAL/RV10": "RealVideo", "V_REAL/RV20": "RealVideo", "V_REAL/RV30": "RealVideo",
        "V_REAL/RV40": "RealVideo", "V_QUICKTIME": "QuickTime video", "V_PRORES": "ProRes",
        "V_UNCOMPRESSED": "uncompressed video", "V_FFV1": "FFV1", "V_DIRAC": "Dirac",
    ]

    static func mapping(for track: MatroskaTrack, firstFrame: () -> Data?) -> TrackMapping {
        if let encoding = track.contentEncoding {
            return .unsupported("its \(track.kindName) track uses \(encoding)")
        }
        switch track.kind {
        case .video: return videoMapping(track, firstFrame: firstFrame)
        case .audio: return audioMapping(track)
        default: return .unsupported("\(track.kindName) tracks are not played")
        }
    }

    // MARK: Video

    private static func videoMapping(_ track: MatroskaTrack, firstFrame: () -> Data?) -> TrackMapping {
        let codec = track.codecID
        guard track.pixelWidth > 0, track.pixelHeight > 0 else {
            return .unsupported("its video track has no frame size")
        }
        let description: CMVideoFormatDescription?
        switch codec {
        case "V_MPEG4/ISO/AVC":
            guard !track.codecPrivate.isEmpty else { return .unsupported("its H.264 track has no decoder configuration") }
            description = videoFormat(kCMVideoCodecType_H264, atom: ("avcC", track.codecPrivate), track: track)
        case "V_MPEGH/ISO/HEVC":
            guard !track.codecPrivate.isEmpty else { return .unsupported("its HEVC track has no decoder configuration") }
            description = videoFormat(kCMVideoCodecType_HEVC, atom: ("hvcC", track.codecPrivate), track: track)
        case "V_AV1":
            guard !track.codecPrivate.isEmpty else { return .unsupported("its AV1 track has no decoder configuration") }
            description = videoFormat(kCMVideoCodecType_AV1, atom: ("av1C", track.codecPrivate), track: track)
        case "V_VP9":
            guard let config = vp9Configuration(track, keyframe: firstFrame()) else {
                return .unsupported("its VP9 track could not be described")
            }
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            description = videoFormat(kCMVideoCodecType_VP9, atom: ("vpcC", config), track: track)
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP":
            description = videoFormat(kCMVideoCodecType_MPEG4Video,
                                      atom: ("esds", esdsBox(objectType: 0x20, streamType: 0x04, config: track.codecPrivate)),
                                      track: track)
        case "V_MS/VFW/FOURCC":
            return vfwMapping(track, firstFrame: firstFrame)
        default:
            let name = undecodableVideo[codec] ?? codec
            return .unsupported("its video is \(name), which macOS can't decode")
        }
        guard let description else { return .unsupported("its \(codec) video track could not be described") }
        return .video(description)
    }

    private static func videoFormat(_ codec: CMVideoCodecType, atom: (String, Data)?, track: MatroskaTrack,
                                    pixelAspect: (Int, Int)? = nil) -> CMVideoFormatDescription? {
        var extensions: [CFString: Any] = [:]
        if let atom {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [atom.0: atom.1] as CFDictionary
        }
        var aspect = pixelAspect
        if aspect == nil, track.displayUnit == 0, let dw = track.displayWidth, let dh = track.displayHeight, dw > 0, dh > 0 {
            aspect = (dw * track.pixelHeight, dh * track.pixelWidth)
        }
        if var (h, v) = aspect, h > 0, v > 0 {
            let divisor = gcd(h, v)
            h /= divisor
            v /= divisor
            if h != v {
                extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                    kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: h,
                    kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: v,
                ] as CFDictionary
            }
        }
        // Colour code points share ISO/IEC 23091-2 numbering with CoreVideo.
        // Leaving them out when unspecified lets the decoder read the VUI.
        let colour = track.colour
        if ![0, 2].contains(colour.primaries),
           let primaries = CVColorPrimariesGetStringForIntegerCodePoint(Int32(colour.primaries)) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries.takeUnretainedValue()
        }
        if ![0, 2].contains(colour.transfer),
           let transfer = CVTransferFunctionGetStringForIntegerCodePoint(Int32(colour.transfer)) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer.takeUnretainedValue()
        }
        if ![0, 2].contains(colour.matrix),
           let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(colour.matrix)) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix.takeUnretainedValue()
        }
        if colour.range == 1 || colour.range == 2 {
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = colour.range == 2
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: Int32(clamping: track.pixelWidth),
            height: Int32(clamping: track.pixelHeight),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// Builds a VPCodecConfigurationRecord (`vpcC`, version 1). Matroska's
    /// optional VP9 CodecPrivate is a different, sparse format, so the
    /// profile and colour configuration come from the first keyframe's
    /// uncompressed header, which every VP9 stream begins with.
    private static func vp9Configuration(_ track: MatroskaTrack, keyframe: Data?) -> Data? {
        guard let frame = keyframe, frame.count >= 10 else { return nil }
        var bits = BitReader(frame)
        guard bits.read(2) == 2 else { return nil }            // frame_marker
        let profileLow = bits.read(1)
        let profileHigh = bits.read(1)
        let profile = profileHigh << 1 | profileLow
        if profile == 3 { _ = bits.read(1) }
        guard bits.read(1) == 0 else { return nil }            // show_existing_frame
        guard bits.read(1) == 0 else { return nil }            // frame_type == KEY_FRAME
        _ = bits.read(2)                                       // show_frame, error_resilient_mode
        guard bits.read(8) == 0x49, bits.read(8) == 0x83, bits.read(8) == 0x42 else { return nil }
        var bitDepth = 8
        if profile >= 2 { bitDepth = bits.read(1) == 1 ? 12 : 10 }
        let colorSpace = bits.read(3)
        var fullRange = 0
        var chroma = 1 // 4:2:0 colocated with luma
        if colorSpace != 7 { // not sRGB
            fullRange = bits.read(1)
            if profile == 1 || profile == 3 {
                let sx = bits.read(1)
                let sy = bits.read(1)
                chroma = sx == 1 && sy == 0 ? 2 : (sx == 0 && sy == 0 ? 3 : 1)
            }
        } else {
            fullRange = 1
            chroma = 3
        }
        // VP9 colour_space → ISO/IEC 23091-2 matrix coefficients.
        let matrixForColorSpace = [2, 6, 1, 6, 7, 9, 2, 0]
        let colour = track.colour
        let primaries = [0, 2].contains(colour.primaries) ? 2 : colour.primaries
        let transfer = [0, 2].contains(colour.transfer) ? 2 : colour.transfer
        let matrix = [0, 2].contains(colour.matrix) ? matrixForColorSpace[colorSpace] : colour.matrix

        var record = Data([1, 0, 0, 0])                         // version 1, flags
        record.append(UInt8(profile))
        record.append(0)                                        // level: unspecified
        record.append(UInt8(bitDepth << 4 | chroma << 1 | fullRange))
        record.append(UInt8(primaries))
        record.append(UInt8(transfer))
        record.append(UInt8(matrix))
        record.append(contentsOf: [0, 0])                       // no codec initialization data
        return record
    }

    // MARK: Video for Windows

    /// What a Video for Windows FourCC (upper-cased) holds, for the codecs
    /// AVI files actually carry.
    enum VFWCodec: Equatable {
        case mpeg4, h264, mjpeg, dv, dvcpro, dvcpro50
        case undecodable(String)

        init(_ fourCC: FourCC) {
            if fourCC.raw == 0 || fourCC.raw == 0x0300_0000 {
                self = .undecodable("uncompressed video")   // BI_RGB, BI_BITFIELDS
                return
            }
            let code = fourCC.description.uppercased()
            switch code {
            case "XVID", "DIVX", "DX50", "DIV1", "FMP4", "MP4V", "M4S2", "MP4S", "3IV2", "3IVD", "DXGM", "RMP4",
                 "BLZ0", "UMP4", "SMP4", "HDX4", "XVIX", "DM4V", "GEOV", "SEDG", "WV1F", "M4CC", "FVFW", "LMP4":
                self = .mpeg4
            case "H264", "X264", "AVC1", "DAVC", "VSSH", "SMV2", "Q264", "V264", "GAVC", "UMSV":
                self = .h264
            case "MJPG", "AVRN", "AVDJ", "DMB1", "JPEG", "IJPG", "AVI1", "JPGL", "SLMJ", "CJPG", "ACDV", "QIVG", "MJPA":
                self = .mjpeg
            case "DVSD", "CDVC", "DVCS", "DVC ", "DVCP", "DVSL":
                self = .dv
            case "DV25":
                self = .dvcpro
            case "DV50":
                self = .dvcpro50
            case "DIV3", "DIV4", "DIV5", "DIV6", "DIV2", "MP43", "MPG3", "MP42", "MPG4", "MP41", "AP41", "COL1", "DVX3", "NAVI":
                self = .undecodable("DivX 3 (Microsoft MPEG-4)")
            case "WMV1", "WMV2", "WMV3", "WMVA", "WVC1", "WVP2":
                self = .undecodable("Windows Media Video")
            case "HEVC", "H265", "HVC1", "HEV1", "X265":
                self = .undecodable("HEVC in AVI")
            case "CVID": self = .undecodable("Cinepak")
            case "IV31", "IV32", "IV41", "IV50": self = .undecodable("Intel Indeo")
            case "MSVC", "CRAM", "WHAM": self = .undecodable("Microsoft Video 1")
            case "MRLE": self = .undecodable("Microsoft RLE")
            case "HFYU", "FFVH": self = .undecodable("HuffYUV")
            case "FFV1": self = .undecodable("FFV1")
            case "VP80", "VP8 ": self = .undecodable("VP8")
            case "VP90": self = .undecodable("VP9 in AVI")
            case "MPG1", "MPG2", "MPEG", "MPGV", "MMES", "M2V1": self = .undecodable("MPEG-2")
            case "TSCC", "TSC2": self = .undecodable("TechSmith screen capture")
            case "CSCD": self = .undecodable("CamStudio")
            default:
                let printable = fourCC.bytes.allSatisfy { (0x20...0x7E).contains($0) }
                self = .undecodable(printable ? "the “\(fourCC)” codec" : "an unknown codec")
            }
        }
    }

    private static func vfwMapping(_ track: MatroskaTrack, firstFrame: () -> Data?) -> TrackMapping {
        guard let info = BitmapInfo(track.codecPrivate) else {
            return .unsupported("its video track has no format description")
        }
        let description: CMVideoFormatDescription?
        switch VFWCodec(info.compression) {
        case .mpeg4:
            guard let headers = mpeg4Headers(info.extra) ?? firstFrame().flatMap(mpeg4Headers) else {
                return .unsupported("its MPEG-4 video has no stream header")
            }
            description = videoFormat(kCMVideoCodecType_MPEG4Video,
                                      atom: ("esds", esdsBox(objectType: 0x20, streamType: 0x04, config: headers)),
                                      track: track)
        case .h264:
            // Rewritten to V_MPEG4/ISO/AVC before mapping; reaching here
            // means the stream could not be read.
            return .unsupported("its H.264 video could not be read")
        case .mjpeg:
            description = videoFormat(kCMVideoCodecType_JPEG, atom: nil, track: track)
        case .dv, .dvcpro, .dvcpro50:
            let codec = VFWCodec(info.compression)
            let pal: Bool
            switch track.pixelHeight {
            case 480: pal = false
            case 576: pal = true
            default: return .unsupported("its DV video has an unusual frame size (\(track.pixelWidth)×\(track.pixelHeight))")
            }
            let type: CMVideoCodecType
            switch codec {
            case .dvcpro: type = pal ? kCMVideoCodecType_DVCProPAL : kCMVideoCodecType_DVCNTSC
            case .dvcpro50: type = pal ? kCMVideoCodecType_DVCPro50PAL : kCMVideoCodecType_DVCPro50NTSC
            default: type = pal ? kCMVideoCodecType_DVCPAL : kCMVideoCodecType_DVCNTSC
            }
            let wide = firstFrame().map(dvIsWidescreen) ?? false
            // ffmpeg's DV sample aspect ratios: 4:3 and 16:9, NTSC and PAL.
            let aspect = pal ? (wide ? (64, 45) : (16, 15)) : (wide ? (32, 27) : (8, 9))
            description = videoFormat(type, atom: nil, track: track, pixelAspect: aspect)
        case .undecodable(let name):
            return .unsupported("its video is \(name), which macOS can't decode")
        }
        guard let description else { return .unsupported("its \(info.compression) video track could not be described") }
        return .video(description)
    }

    /// The MPEG-4 Part 2 stream headers (visual object sequence, visual
    /// object, video object layer) that open a stream, up to its first VOP
    /// or group of VOPs: the decoder configuration an `esds` carries. AVI
    /// muxers put them in the BITMAPINFOHEADER or only in the first
    /// keyframe.
    static func mpeg4Headers(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var start: Int?
        var sawLayer = false
        var i = 0
        while i + 4 <= b.count {
            guard b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 else {
                i += 1
                continue
            }
            let code = b[i + 3]
            if code == 0xB6 || code == 0xB3 { break }        // VOP, GOV
            if start == nil, code == 0xB0 || code == 0xB5 || code <= 0x2F { start = i }
            if (0x20...0x2F).contains(code) { sawLayer = true }
            i += 3
        }
        guard sawLayer, let start else { return nil }
        let end = i + 4 <= b.count ? i : b.count
        return Data(b[start..<end])
    }

    /// Whether a DV frame says its picture is 16:9, from the VAUX source
    /// control pack in its first DIF sequence (IEC 61834; ffmpeg reads the
    /// same pack, at the same place).
    static func dvIsWidescreen(_ frame: Data) -> Bool {
        let b = [UInt8](frame.prefix(480))
        guard b.count >= 458 else { return false }
        let pack = 80 * 5 + 48 + 5
        guard b[pack] == 0x61 else { return false }
        let display = b[pack + 2] & 0x07
        let apt = b[4] & 0x07
        return display == 0x02 || (apt == 0 && display == 0x07)
    }

    // MARK: Audio

    private static func audioMapping(_ track: MatroskaTrack) -> TrackMapping {
        let codec = track.codecID
        let rate = track.samplingFrequency
        let channels = UInt32(clamping: track.channels)

        if codec == "A_AAC" || codec.hasPrefix("A_AAC/") {
            let config = codec == "A_AAC" && !track.codecPrivate.isEmpty
                ? track.codecPrivate
                : legacyAACConfig(codecID: codec, track: track)
            guard let config, let parsed = AudioSpecificConfig(config) else {
                return .unsupported("its AAC track has no usable decoder configuration")
            }
            let coreRate = parsed.sampleRate ?? rate
            return audio(kAudioFormatMPEG4AAC, rate: coreRate, channels: parsed.channels ?? channels,
                         framesPerPacket: 1024,
                         cookie: esDescriptor(objectType: 0x40, streamType: 0x05, config: config),
                         timing: .fixed(1024), start: .movieHidesPriming(2112))
        }

        switch codec {
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10":
            return audio(kAudioFormatAC3, rate: rate, channels: channels, framesPerPacket: 1536, cookie: nil,
                         timing: .fixed(1536), start: .decoderHides(256))
        case "A_EAC3":
            return audio(kAudioFormatEnhancedAC3, rate: rate, channels: channels, framesPerPacket: 1536, cookie: nil,
                         timing: .fromTimestamps(granularity: 256), start: .decoderHides(256))
        case "A_MPEG/L3":
            let samples: UInt32 = rate >= 32000 ? 1152 : 576
            return audio(kAudioFormatMPEGLayer3, rate: rate, channels: channels, framesPerPacket: samples, cookie: nil,
                         timing: .fixed(Int64(samples)), start: .decoderHides(529))
        case "A_MPEG/L2":
            return audio(kAudioFormatMPEGLayer2, rate: rate, channels: channels, framesPerPacket: 1152, cookie: nil,
                         timing: .fixed(1152), start: .decoderHides(241))
        case "A_MPEG/L1":
            // Not measured; Layer I shares Layer II's synthesis filterbank.
            return audio(kAudioFormatMPEGLayer1, rate: rate, channels: channels, framesPerPacket: 384, cookie: nil,
                         timing: .fixed(384), start: .decoderHides(241))
        case "A_FLAC":
            guard let flac = FLACConfig(track.codecPrivate) else {
                return .unsupported("its FLAC track has no stream information")
            }
            let timing: AudioPacketTiming = flac.fixedBlockSize.map { .fixed(Int64($0)) } ?? .fromTimestamps(granularity: 1)
            return audio(kAudioFormatFLAC, rate: Double(flac.sampleRate), channels: UInt32(flac.channels),
                         framesPerPacket: UInt32(flac.fixedBlockSize ?? 0), cookie: flac.cookie, timing: timing, start: .exact)
        case "A_OPUS":
            guard track.codecPrivate.count >= 19 else { return .unsupported("its Opus track has no OpusHead") }
            // Packets vary from 120 to 5760 samples. A fixed count here
            // makes AVFoundation ignore the track's edit, so the pre-skip
            // would never be trimmed.
            return audio(kAudioFormatOpus, rate: 48000, channels: channels, framesPerPacket: 0,
                         cookie: track.codecPrivate, timing: .opus, start: .exact)
        case "A_ALAC":
            guard track.codecPrivate.count >= 24 else { return .unsupported("its ALAC track has no configuration") }
            let frameLength = track.codecPrivate.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return audio(kAudioFormatAppleLossless, rate: rate, channels: channels, framesPerPacket: frameLength,
                         cookie: track.codecPrivate, timing: .fixed(Int64(max(1, frameLength))), start: .exact)
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            return pcm(track)
        case "A_MS/ACM":
            return acmMapping(track)
        case "A_DV/EMBEDDED":
            return .unsupported("its sound is stored inside the DV video frames (a type-1 DV file), which Latent can't play yet")
        default:
            let name = undecodableAudio[codec] ?? codec
            return .unsupported("its audio is \(name), which macOS can't decode")
        }
    }

    private static func audio(_ format: AudioFormatID, rate: Double, channels: UInt32, framesPerPacket: UInt32,
                              cookie: Data?, timing: AudioPacketTiming, start: AudioStart) -> TrackMapping {
        guard rate > 0, rate.isFinite, channels > 0 else {
            return .unsupported("its audio track has no sample rate or channel count")
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: format, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0
        )
        return makeAudio(&asbd, cookie: cookie, timing: timing, start: start)
    }

    private static func pcm(_ track: MatroskaTrack) -> TrackMapping {
        let depth = track.bitDepth ?? 16
        guard [8, 16, 24, 32, 64].contains(depth), track.channels > 0 else {
            return .unsupported("its PCM track has an unusual sample format")
        }
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        switch track.codecID {
        case "A_PCM/FLOAT/IEEE":
            guard depth == 32 || depth == 64 else { return .unsupported("its float PCM track has an unusual sample format") }
            flags |= kAudioFormatFlagIsFloat
        case "A_PCM/INT/BIG":
            flags |= kAudioFormatFlagIsBigEndian | (depth > 8 ? kAudioFormatFlagIsSignedInteger : 0)
        default:
            // Matroska little-endian PCM is unsigned at 8 bits, signed above.
            if depth > 8 { flags |= kAudioFormatFlagIsSignedInteger }
        }
        let bytesPerFrame = UInt32(depth / 8 * track.channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: track.samplingFrequency, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(track.channels), mBitsPerChannel: UInt32(depth), mReserved: 0
        )
        return makeAudio(&asbd, cookie: nil, timing: .pcm(bytesPerFrame: Int(bytesPerFrame)), start: .exact)
    }

    /// Windows audio codecs described by a WAVEFORMATEX, which AVI files
    /// (and Matroska's `A_MS/ACM`) carry.
    private static func acmMapping(_ track: MatroskaTrack) -> TrackMapping {
        guard let wave = WaveFormat(track.codecPrivate), wave.channels > 0, wave.sampleRate > 0 else {
            return .unsupported("its audio track has no format description")
        }
        let rate = Double(wave.sampleRate)
        let channels = UInt32(wave.channels)
        switch wave.tag {
        case WaveFormat.imaADPCM, WaveFormat.msADPCM, WaveFormat.gsm610:
            guard let frames = wave.samplesPerBlock, frames > 0, wave.blockAlign > 0 else {
                return .unsupported("its ADPCM audio has no block size")
            }
            let format: AudioFormatID = switch wave.tag {
            case WaveFormat.imaADPCM: kAudioFormatDVIIntelIMA
            case WaveFormat.msADPCM: 0x6D73_0002 // 'ms\0\2', CoreAudio's Microsoft ADPCM decoder
            default: kAudioFormatMicrosoftGSM
            }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: format, mFormatFlags: 0, mBytesPerPacket: UInt32(wave.blockAlign),
                mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0, mChannelsPerFrame: channels,
                mBitsPerChannel: 0, mReserved: 0
            )
            return makeAudio(&asbd, cookie: nil, timing: .fixed(Int64(frames)), start: .exact)
        case WaveFormat.muLaw, WaveFormat.aLaw:
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: wave.tag == WaveFormat.muLaw ? kAudioFormatULaw : kAudioFormatALaw,
                mFormatFlags: 0, mBytesPerPacket: channels, mFramesPerPacket: 1, mBytesPerFrame: channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 8, mReserved: 0
            )
            return makeAudio(&asbd, cookie: nil, timing: .pcm(bytesPerFrame: Int(channels)), start: .exact)
        default:
            let name: String = switch wave.tag {
            case 0x0160, 0x0161: "Windows Media Audio"
            case 0x0162: "Windows Media Audio Pro"
            case 0x0163: "Windows Media Audio Lossless"
            case 0x0022: "DSP Group TrueSpeech"
            case 0x0270: "ATRAC3"
            case 0x0130: "ACELP.net"
            case 0x0040, 0x0045, 0x0064, 0x0140: "G.72x"
            case 0x566F, 0x674F, 0x6750, 0x6751, 0x676F, 0x6770, 0x6771: "Vorbis"
            case WaveFormat.dts: "DTS"
            default: String(format: "Windows audio format 0x%04X", wave.tag)
            }
            return .unsupported("its audio is \(name), which macOS can't decode")
        }
    }

    private static func makeAudio(_ asbd: inout AudioStreamBasicDescription, cookie: Data?,
                                  timing: AudioPacketTiming, start: AudioStart) -> TrackMapping {
        var description: CMAudioFormatDescription?
        let status: OSStatus
        if let cookie, !cookie.isEmpty {
            status = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                    magicCookieSize: raw.count, magicCookie: raw.baseAddress, extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            return .unsupported("its audio track could not be described (\(status))")
        }
        return .audio(description, timing, start)
    }

    /// Old Matroska files name the AAC profile in the codec ID and carry no
    /// AudioSpecificConfig; synthesize the two-byte one they imply.
    private static func legacyAACConfig(codecID: String, track: MatroskaTrack) -> Data? {
        let profile: UInt8
        if codecID.hasSuffix("/MAIN") { profile = 1 }
        else if codecID.hasSuffix("/SSR") { profile = 3 }
        else if codecID.hasSuffix("/LTP") { profile = 4 }
        else { profile = 2 } // LC, and LC/SBR whose SBR the decoder finds implicitly
        guard let rateIndex = AudioSpecificConfig.rates.firstIndex(of: track.samplingFrequency) else { return nil }
        let channels = UInt8(clamping: min(track.channels, 7))
        return Data([profile << 3 | UInt8(rateIndex) >> 1, UInt8(rateIndex & 1) << 7 | channels << 3])
    }

    // MARK: MPEG-4 descriptors

    /// An ES_Descriptor wrapping `config` as DecoderSpecificInfo. This is the
    /// magic-cookie form CoreAudio's AAC decoder takes.
    static func esDescriptor(objectType: UInt8, streamType: UInt8, config: Data) -> Data {
        var decoderSpecific = Data([0x05]) + descriptorLength(config.count)
        decoderSpecific.append(config)
        var decoderConfig = Data([objectType, streamType << 2 | 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        decoderConfig.append(decoderSpecific)
        decoderConfig = Data([0x04]) + descriptorLength(decoderConfig.count) + decoderConfig
        var body = Data([0, 0, 0]) // ES_ID, flags
        body.append(decoderConfig)
        body.append(contentsOf: [0x06, 0x01, 0x02]) // SLConfigDescriptor: MP4 predefined
        return Data([0x03]) + descriptorLength(body.count) + body
    }

    /// The `esds` sample-description atom body: a full-box header then the
    /// ES_Descriptor.
    static func esdsBox(objectType: UInt8, streamType: UInt8, config: Data) -> Data {
        Data([0, 0, 0, 0]) + esDescriptor(objectType: objectType, streamType: streamType, config: config)
    }

    private static func descriptorLength(_ length: Int) -> Data {
        Data([
            UInt8(0x80 | (length >> 21) & 0x7F),
            UInt8(0x80 | (length >> 14) & 0x7F),
            UInt8(0x80 | (length >> 7) & 0x7F),
            UInt8(length & 0x7F),
        ])
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}

/// Just enough of an MPEG-4 AudioSpecificConfig to learn the core sample
/// rate and channel count.
struct AudioSpecificConfig {
    static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    let objectType: Int
    let sampleRate: Double?
    let channels: UInt32?

    init?(_ data: Data) {
        guard data.count >= 2 else { return nil }
        var bits = BitReader(data)
        var objectType = bits.read(5)
        if objectType == 31 { objectType = 32 + bits.read(6) }
        let rateIndex = bits.read(4)
        var rate: Double?
        if rateIndex == 15 {
            rate = Double(bits.read(24))
        } else if rateIndex < Self.rates.count {
            rate = Self.rates[rateIndex]
        }
        let channelConfig = bits.read(4)
        self.objectType = objectType
        self.sampleRate = rate
        // Channel configuration 0 means "described in the bitstream".
        self.channels = channelConfig == 0 ? nil : UInt32(channelConfig == 7 ? 8 : channelConfig)
    }
}

/// FLAC STREAMINFO, from Matroska's CodecPrivate ("fLaC" + metadata blocks).
struct FLACConfig {
    let sampleRate: Int
    let channels: Int
    let fixedBlockSize: Int?
    /// The `dfLa` box CoreAudio's FLAC decoder takes as its magic cookie.
    let cookie: Data

    init?(_ codecPrivate: Data) {
        var blocks = Data(codecPrivate)
        if blocks.starts(with: Array("fLaC".utf8)) { blocks.removeFirst(4) }
        // First metadata block must be STREAMINFO (type 0, 34 bytes).
        guard blocks.count >= 38, blocks[blocks.startIndex] & 0x7F == 0 else { return nil }
        let info = blocks.dropFirst(4)
        let bytes = Array(info.prefix(18))
        let minBlock = Int(bytes[0]) << 8 | Int(bytes[1])
        let maxBlock = Int(bytes[2]) << 8 | Int(bytes[3])
        sampleRate = Int(bytes[10]) << 12 | Int(bytes[11]) << 4 | Int(bytes[12]) >> 4
        channels = Int((bytes[12] >> 1) & 0x07) + 1
        fixedBlockSize = minBlock == maxBlock && minBlock > 0 ? minBlock : nil
        guard sampleRate > 0 else { return nil }
        // A complete `dfLa` box (size, type, version/flags, metadata
        // blocks); CoreAudio rejects the bare blocks or STREAMINFO alone.
        let body = Data([0, 0, 0, 0]) + blocks
        let size = UInt32(body.count + 8)
        cookie = withUnsafeBytes(of: size.bigEndian) { Data($0) } + Data("dfLa".utf8) + body
    }
}

/// MSB-first bit reader over a byte buffer. Reads past the end yield zeros.
struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = bit >> 3
            let b = byteIndex < bytes.count ? Int(bytes[byteIndex]) : 0
            value = value << 1 | (b >> (7 - (bit & 7))) & 1
            bit += 1
        }
        return value
    }
}

/// Samples in one Opus packet at 48 kHz, from its TOC byte (RFC 6716 §3.1).
func opusPacketSamples(prefix: UInt64) -> Int64? {
    let toc = Int(prefix >> 56)
    let config = toc >> 3
    let frameSamples: Int64
    switch config {
    case 0...11: frameSamples = [480, 960, 1920, 2880][config & 3]
    case 12...15: frameSamples = [480, 960][config & 1]
    default: frameSamples = [120, 240, 480, 960][config & 3]
    }
    let frames: Int64
    switch toc & 3 {
    case 0: frames = 1
    case 1, 2: frames = 2
    default: frames = Int64((prefix >> 48) & 0x3F)
    }
    guard frames > 0 else { return nil }
    return frameSamples * frames
}
