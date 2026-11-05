import Foundation

/// Just enough H.264 (ITU-T H.264) to carry an Annex B stream from an AVI
/// into a QuickTime movie: split NAL units, build an `avcC` from the
/// parameter sets, and recover each picture's order count, because AVI keeps
/// frames in decode order with no presentation times.
enum H264 {
    static let sliceNonIDR: UInt8 = 1
    static let sliceIDR: UInt8 = 5
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let accessUnitDelimiter: UInt8 = 9
    static let filler: UInt8 = 12

    /// NAL unit payloads in an Annex B byte stream (start codes removed).
    static func annexBUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1].code : bytes.count
            while end > start.payload, bytes[end - 1] == 0 { end -= 1 } // trailing_zero_8bits
            if end > start.payload { units.append(Data(bytes[start.payload..<end])) }
        }
        return units
    }

    /// NAL units in a length-prefixed (AVCC) sample, or nil when the sizes
    /// do not tile the sample exactly.
    static func lengthPrefixedUnits(_ data: Data, lengthSize: Int) -> [Data]? {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0
        while i < bytes.count {
            guard i + lengthSize <= bytes.count else { return nil }
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(bytes[i + k]) }
            i += lengthSize
            guard length > 0, i + length <= bytes.count else { return nil }
            units.append(Data(bytes[i..<(i + length)]))
            i += length
        }
        return units.isEmpty ? nil : units
    }

    static func startsWithStartCode(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        return b.count >= 3 && b[0] == 0 && b[1] == 0 && (b[2] == 1 || b.count == 4 && b[2] == 0 && b[3] == 1)
    }

    /// An AVCDecoderConfigurationRecord with 4-byte NAL lengths.
    static func avcC(sps: [Data], pps: [Data]) -> Data? {
        guard let first = sps.first, first.count >= 4 else { return nil }
        let b = [UInt8](first)
        var record = Data([1, b[1], b[2], b[3], 0xFF, 0xE0 | UInt8(min(sps.count, 31))])
        for unit in sps.prefix(31) {
            record.append(contentsOf: [UInt8(unit.count >> 8 & 0xFF), UInt8(unit.count & 0xFF)])
            record.append(unit)
        }
        record.append(UInt8(min(pps.count, 255)))
        for unit in pps.prefix(255) {
            record.append(contentsOf: [UInt8(unit.count >> 8 & 0xFF), UInt8(unit.count & 0xFF)])
            record.append(unit)
        }
        return record
    }

    /// Parameter sets from an existing `avcC`, and its NAL length size.
    static func parseAVCC(_ record: Data) -> (sps: [Data], pps: [Data], lengthSize: Int)? {
        let b = [UInt8](record)
        guard b.count >= 7, b[0] == 1 else { return nil }
        let lengthSize = Int(b[4] & 0x3) + 1
        var i = 5
        func sets(count: Int) -> [Data]? {
            var out: [Data] = []
            for _ in 0..<count {
                guard i + 2 <= b.count else { return nil }
                let length = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard i + length <= b.count else { return nil }
                out.append(Data(b[i..<(i + length)]))
                i += length
            }
            return out
        }
        guard let sps = sets(count: Int(b[5] & 0x1F)) else { return nil }
        i = i < b.count ? i : b.count
        guard i < b.count else { return (sps, [], lengthSize) }
        let ppsCount = Int(b[i])
        i += 1
        guard let pps = sets(count: ppsCount) else { return nil }
        return (sps, pps, lengthSize)
    }

    // MARK: Parameter sets

    struct SequenceParameters {
        var id = 0
        var frameNumBits = 4
        var pocType = 0
        var pocLSBBits = 4
        var frameMBsOnly = true
        var separateColourPlane = false
        var deltaPicOrderAlwaysZero = false

        init?(_ nal: Data) {
            var r = ExpGolomb(rbsp: nal.dropFirst())
            let profile = r.bits(8)
            _ = r.bits(16) // constraint flags, level
            id = r.ue()
            if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
                let chroma = r.ue()
                if chroma == 3 { separateColourPlane = r.bit() }
                _ = r.ue() // bit_depth_luma_minus8
                _ = r.ue() // bit_depth_chroma_minus8
                _ = r.bit() // qpprime_y_zero_transform_bypass_flag
                if r.bit() { // seq_scaling_matrix_present_flag
                    for list in 0..<(chroma == 3 ? 12 : 8) where r.bit() {
                        r.skipScalingList(size: list < 6 ? 16 : 64)
                    }
                }
            }
            frameNumBits = r.ue() + 4
            pocType = r.ue()
            if pocType == 0 {
                pocLSBBits = r.ue() + 4
            } else if pocType == 1 {
                deltaPicOrderAlwaysZero = r.bit()
                _ = r.se()
                _ = r.se()
                let cycle = r.ue()
                for _ in 0..<min(cycle, 255) { _ = r.se() }
            }
            _ = r.ue() // max_num_ref_frames
            _ = r.bit() // gaps_in_frame_num_value_allowed_flag
            _ = r.ue() // pic_width_in_mbs_minus1
            _ = r.ue() // pic_height_in_map_units_minus1
            frameMBsOnly = r.bit()
            guard !r.overrun, frameNumBits <= 16, pocLSBBits <= 16, pocType <= 2 else { return nil }
        }
    }

    struct PictureParameters {
        var id = 0
        var spsID = 0
        var bottomFieldPicOrderPresent = false

        init?(_ nal: Data) {
            var r = ExpGolomb(rbsp: nal.dropFirst())
            id = r.ue()
            spsID = r.ue()
            _ = r.bit() // entropy_coding_mode_flag
            bottomFieldPicOrderPresent = r.bit()
            guard !r.overrun else { return nil }
        }
    }

    /// The slice-header fields that decide picture order.
    struct SliceHeader {
        var firstMB = 0
        var ppsID = 0
        var pocLSB = 0
        var deltaBottom = 0
        var isIDR = false
        var isReference = false

        init?(_ nal: Data, sps: [Int: SequenceParameters], pps: [Int: PictureParameters]) {
            guard let header = nal.first else { return nil }
            isIDR = header & 0x1F == H264.sliceIDR
            isReference = header & 0x60 != 0
            var r = ExpGolomb(rbsp: nal.dropFirst())
            firstMB = r.ue()
            _ = r.ue() // slice_type
            ppsID = r.ue()
            guard let p = pps[ppsID], let s = sps[p.spsID] else { return nil }
            if s.separateColourPlane { _ = r.bits(2) }
            _ = r.bits(s.frameNumBits)
            var fieldPic = false
            if !s.frameMBsOnly {
                fieldPic = r.bit()
                if fieldPic { _ = r.bit() }
            }
            if isIDR { _ = r.ue() }
            if s.pocType == 0 {
                pocLSB = r.bits(s.pocLSBBits)
                if p.bottomFieldPicOrderPresent, !fieldPic { deltaBottom = r.se() }
            }
            guard !r.overrun else { return nil }
        }
    }

    /// Picture order counts for a decode-order sequence of pictures
    /// (8.2.1.1, order count type 0). Returns nil for streams whose output
    /// order is their decode order (types 1 and 2 as used in practice).
    struct OrderCounter {
        private var previousMSB = 0
        private var previousLSB = 0

        mutating func count(_ slice: SliceHeader, sps: SequenceParameters) -> Int? {
            guard sps.pocType == 0 else { return nil }
            if slice.isIDR {
                previousMSB = 0
                previousLSB = 0
            }
            let maxLSB = 1 << sps.pocLSBBits
            var msb = previousMSB
            if slice.pocLSB < previousLSB, previousLSB - slice.pocLSB >= maxLSB / 2 {
                msb += maxLSB
            } else if slice.pocLSB > previousLSB, slice.pocLSB - previousLSB > maxLSB / 2 {
                msb -= maxLSB
            }
            if slice.isReference {
                previousMSB = msb
                previousLSB = slice.pocLSB
            }
            let top = msb + slice.pocLSB
            return min(top, top + slice.deltaBottom)
        }
    }
}

/// Exp-Golomb reader over an RBSP (emulation-prevention bytes removed).
/// Reads past the end yield zeros and set `overrun`.
struct ExpGolomb {
    private let bytes: [UInt8]
    private var position = 0
    private(set) var overrun = false

    init<D: Collection>(rbsp escaped: D) where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(min(escaped.count, 256))
        var zeros = 0
        for b in escaped.prefix(256) {
            if zeros >= 2, b == 3 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        bytes = out
    }

    mutating func bit() -> Bool { bits(1) == 1 }

    mutating func bits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = position >> 3
            if byteIndex >= bytes.count { overrun = true }
            let b = byteIndex < bytes.count ? Int(bytes[byteIndex]) : 0
            value = value << 1 | (b >> (7 - (position & 7))) & 1
            position += 1
        }
        return value
    }

    mutating func ue() -> Int {
        var zeros = 0
        while !bit(), zeros < 32 {
            zeros += 1
            if overrun { return 0 }
        }
        return (1 << zeros) - 1 + bits(zeros)
    }

    mutating func se() -> Int {
        let k = ue()
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }

    mutating func skipScalingList(size: Int) {
        var last = 8
        var next = 8
        for _ in 0..<size where next != 0 {
            next = (last + se() + 256) % 256
            last = next == 0 ? last : next
        }
    }
}
