import Foundation
import CoreMedia
import VideoToolbox

/// Decodes one keyframe of a video track before the movie promises it.
///
/// A format description says what a stream claims to be, not whether this
/// Mac can decode it. Several common files describe cleanly and then fail
/// frame by frame: DivX and Xvid using MPEG-4 Advanced Simple features
/// (B-frames, quarter-pixel motion), 10-bit or 4:2:2 H.264, Motion JPEG laid
/// out the way ffmpeg writes 4:2:2, AV1 without a hardware decoder. AVPlayer
/// would show those as a black picture with no error. One decoded frame
/// tells them apart, so the viewer can say why instead.
enum DecodeProbe {
    /// Statuses that say the decoder is busy rather than unable: the track
    /// is kept and AVPlayer is left to try.
    private static let transient: Set<OSStatus> = [
        kVTVideoDecoderNotAvailableNowErr, kVTVideoDecoderMalfunctionErr, kVTInvalidSessionErr,
    ]

    /// Nil when `frame` decodes to a picture; otherwise why it did not, in
    /// words a viewer can show.
    static func failure(description: CMVideoFormatDescription, keyframe frame: Data) -> String? {
        guard let status = decode(description: description, frame: frame), !transient.contains(status) else {
            return nil
        }
        return reason(for: description, status: status)
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var status: OSStatus?
        private var pictures = 0

        func record(_ status: OSStatus, picture: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if status != noErr, self.status == nil { self.status = status }
            if status == noErr, picture { pictures += 1 }
        }

        var outcome: OSStatus? {
            lock.lock()
            defer { lock.unlock() }
            if let status { return status }
            return pictures > 0 ? nil : kVTVideoDecoderBadDataErr
        }
    }

    /// Nil on success, else the failing status.
    private static func decode(description: CMVideoFormatDescription, frame: Data) -> OSStatus? {
        guard !frame.isEmpty else { return nil }
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        )
        guard created == noErr, let session else { return created }
        defer { VTDecompressionSessionInvalidate(session) }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frame.count, flags: 0, blockBufferOut: &block
        )
        guard status == noErr, let block else { return nil }
        status = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: frame.count)
        }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = frame.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }

        let result = Result()
        let submitted = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            result.record(status, picture: image != nil)
        }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if submitted != noErr { return submitted }
        return result.outcome
    }

    private static func reason(for description: CMVideoFormatDescription, status: OSStatus) -> String {
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_MPEG4Video:
            return "its video is DivX or Xvid using features macOS can't decode (B-frames, quarter-pixel or global motion)"
        case kCMVideoCodecType_H264:
            let atoms = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            if let avcC = atoms?["avcC"] as? Data, avcC.count > 1, [110, 122, 244, 44].contains(avcC[avcC.startIndex + 1]) {
                return "its H.264 video is 10-bit or 4:2:2 (a High 10 or High 4:2:2 profile), which macOS can't decode"
            }
            return "its H.264 video could not be decoded on this Mac"
        case kCMVideoCodecType_JPEG:
            return "its Motion JPEG video uses a layout macOS can't decode"
        case kCMVideoCodecType_AV1:
            return "its AV1 video needs a hardware decoder this Mac doesn't have"
        default:
            return "its video could not be decoded on this Mac (error \(status))"
        }
    }
}
