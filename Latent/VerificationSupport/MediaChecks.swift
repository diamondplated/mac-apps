import Foundation
import AVFoundation
import CoreMedia

/// Decoding helpers shared by the Matroska and AVI verifications: they read
/// a movie the way AVPlayer would and report what came out.
enum MediaChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func writeTemporary(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-media-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    /// Video frames decoded (counting from the track's first frame, not the
    /// repeat AVFoundation draws over a leading empty edit) and seconds of
    /// audio decoded from the first audio track.
    static func decodeAll(_ asset: AVAsset) async throws -> (videoFrames: Int, audioSeconds: Double) {
        let reader = try AVAssetReader(asset: asset)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        var firstFrame = CMTime.zero
        if let videoTrack, let media = try await videoTrack.load(.segments).first(where: { !$0.isEmpty }) {
            firstFrame = media.timeMapping.target.start
        }
        let video = videoTrack.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        }
        if let video { reader.add(video) }
        if let audio { reader.add(audio) }
        guard reader.startReading() else {
            throw Failure(description: "reader failed to start: \(String(describing: reader.error))")
        }
        var frames = 0
        while let sample = video?.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil, CMSampleBufferGetPresentationTimeStamp(sample) >= firstFrame {
                frames += 1
            }
        }
        var seconds = 0.0
        while let sample = audio?.copyNextSampleBuffer() {
            seconds += CMSampleBufferGetDuration(sample).seconds
        }
        guard reader.status == .completed else {
            throw Failure(description: "decoding stopped: \(String(describing: reader.error))")
        }
        return (frames, seconds)
    }

    /// Presentation time of the first bright video frame and of the first
    /// loud audio sample.
    static func flashAndClick(_ asset: AVAsset) async throws -> (flash: Double, click: Double) {
        let found = try await firstFlashAndClick(asset)
        guard let flash = found.flash else { throw Failure(description: "no flash found in the video") }
        guard let click = found.click else { throw Failure(description: "no click found in the audio") }
        return (flash, click)
    }

    /// The first loud audio sample of a movie with no picture.
    static func click(_ asset: AVAsset) async throws -> Double {
        guard let click = try await firstFlashAndClick(asset).click else {
            throw Failure(description: "no click found in the audio")
        }
        return click
    }

    private static func firstFlashAndClick(_ asset: AVAsset) async throws -> (flash: Double?, click: Double?) {
        let reader = try AVAssetReader(asset: asset)
        let video = try await asset.loadTracks(withMediaType: .video).first.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
            ])
        }
        if let video { reader.add(video) }
        if let audio { reader.add(audio) }
        guard reader.startReading() else {
            throw Failure(description: "reader failed to start: \(String(describing: reader.error))")
        }

        var flash: Double?
        while let sample = video?.copyNextSampleBuffer() {
            guard flash == nil, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let middle = CVPixelBufferGetBytesPerRow(pixels) * (CVPixelBufferGetHeight(pixels) / 2) + 40
            let bright = base[middle] > 128
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            if bright { flash = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
        }

        var click: Double?
        while let sample = audio?.copyNextSampleBuffer() {
            guard click == nil, let format = CMSampleBufferGetFormatDescription(sample),
                  let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let loud = floatSamples(sample).firstIndex(where: { abs($0) > 0.3 }) {
                click = start + Double(loud) / rate
            }
        }
        return (flash, click)
    }

    private static func floatSamples(_ sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        values.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        return values
    }

    /// Every sample of an audio track (the first one by default) that plays,
    /// as 16-bit PCM, and the time the first one plays.
    ///
    /// Playback stops at the end of the track's time range. The reader
    /// sometimes keeps going past it with a compressed decoder's flushed
    /// delay (529 samples of MP3, on an occasional run of the same movie),
    /// so samples past the end are dropped to make two decodes comparable.
    static func decodePCM16(_ asset: AVAsset, track index: Int = 0) async throws -> (samples: [Int16], start: CMTime) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard index < tracks.count else { throw Failure(description: "no audio track \(index)") }
        let end = try await tracks[index].load(.timeRange).end
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(description: "reader failed to start: \(String(describing: reader.error))")
        }
        var samples: [Int16] = []
        var start = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if !start.isValid { start = time }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            let left = CMTimeConvertScale(end - time, timescale: Int32(stream.mSampleRate), method: .roundHalfAwayFromZero)
            let playing = max(0, Int(left.value)) * Int(stream.mChannelsPerFrame)
            samples += chunk.prefix(playing)
        }
        guard reader.status == .completed else {
            throw Failure(description: "decoding stopped: \(String(describing: reader.error))")
        }
        return (samples, start)
    }
}
