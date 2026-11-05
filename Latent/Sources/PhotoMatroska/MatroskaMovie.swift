import Foundation
import AVFoundation
import CoreMedia

/// A track the movie leaves out, with the reason in words a viewer can show.
public struct MatroskaSkippedTrack: Sendable, Equatable {
    public let number: UInt64
    public let kind: String
    public let codecID: String
    public let reason: String
}

/// Plays a Matroska file through AVFoundation without converting it.
///
/// AVFoundation has no Matroska demuxer, but a QuickTime movie may keep its
/// samples in another file and describe them by byte range. This builds such
/// a movie in memory: every video and audio frame found by `MatroskaIndex`
/// becomes a sample reference into the original `.mkv`, with H.264, HEVC,
/// AV1 and the common audio codecs described the way QuickTime describes
/// them. AVPlayer, AVAssetImageGenerator and AVAssetReader then read the
/// original bytes directly: nothing is copied, transcoded or written to disk.
///
/// The movie is immutable once `load` returns, which is what makes handing
/// it across concurrency domains sound.
public final class MatroskaMovie: @unchecked Sendable {
    public let sourceURL: URL
    public let asset: AVAsset
    /// Tracks that could not be played (an unsupported codec, encrypted or
    /// header-compressed frames). Subtitle and attachment tracks are not
    /// listed; Latent never shows them.
    public let skippedTracks: [MatroskaSkippedTrack]
    /// False when the file ended early or `limit` stopped the read.
    public let isComplete: Bool
    public let videoTrackCount: Int
    public let audioTrackCount: Int

    private init(sourceURL: URL, asset: AVAsset, skippedTracks: [MatroskaSkippedTrack],
                 isComplete: Bool, videoTrackCount: Int, audioTrackCount: Int) {
        self.sourceURL = sourceURL
        self.asset = asset
        self.skippedTracks = skippedTracks
        self.isComplete = isComplete
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
    }

    /// Indexes `url` and builds its movie. Synchronous and I/O-bound: call it
    /// off the main actor, or use `open`. `limit` (seconds) reads only the
    /// start of the file, enough for a thumbnail. `progress` is called on
    /// the calling thread with the overall fraction done: reading the file
    /// is the first half, describing its frames to AVFoundation the second.
    /// Reading dominates on a network volume, describing on a local disk
    /// (about two seconds for a two-hour film).
    public static func load(url: URL, limit: Double? = nil,
                            progress: ((Double) -> Void)? = nil) throws -> MatroskaMovie {
        let index = try MatroskaIndex.read(url: url, limit: limit, progress: progress.map { report in
            { report($0 * 0.5) }
        })
        return try build(index, url: url, progress: progress.map { report in
            { report(0.5 + $0 * 0.5) }
        })
    }

    /// `load` on a background thread. Cancelling the calling task stops the
    /// read at the next cluster and throws `CancellationError`.
    public static func open(url: URL, limit: Double? = nil,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> MatroskaMovie {
        let work = Task.detached(priority: .userInitiated) {
            try load(url: url, limit: limit, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func build(_ index: MatroskaIndex, url: URL, progress: ((Double) -> Void)? = nil) throws -> MatroskaMovie {
        let reader = try? FileHandle(forReadingFrom: url)
        defer { try? reader?.close() }

        var skipped: [MatroskaSkippedTrack] = []
        var plans: [(track: MatroskaTrack, mapping: TrackMapping)] = []
        for track in index.tracks where track.kind == .video || track.kind == .audio {
            let mapping = MatroskaCodecs.mapping(for: track) {
                guard let reader, let frame = track.frames.first(where: \.isKeyframe) ?? track.frames.first else { return nil }
                try? reader.seek(toOffset: UInt64(frame.offset))
                return try? reader.read(upToCount: Int(min(frame.size, 64)))
            }
            if case .unsupported(let reason) = mapping {
                skipped.append(MatroskaSkippedTrack(number: track.number, kind: track.kindName,
                                                    codecID: track.codecID, reason: reason))
            } else if track.frames.isEmpty {
                skipped.append(MatroskaSkippedTrack(number: track.number, kind: track.kindName,
                                                    codecID: track.codecID, reason: "its \(track.kindName) track is empty"))
            } else {
                plans.append((track, mapping))
            }
        }
        guard !plans.isEmpty else {
            throw MatroskaError.noPlayableTracks(skipped.map(\.reason))
        }

        let scale = Int64(index.timestampScale)
        // Every track is placed relative to the earliest frame of any played
        // track, which keeps audio and video aligned the way Matroska says.
        let origin = plans.map { plan in plan.track.frames.map(\.timestamp).min() ?? 0 }.min() ?? 0

        let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
        movie.timescale = 90_000

        let videoPlans = plans.filter { $0.track.kind == .video }
        let audioPlans = plans.filter { $0.track.kind == .audio }
        let preferredVideo = preferredTrack(videoPlans.map(\.track))
        let preferredAudio = preferredTrack(audioPlans.map(\.track))

        // Frames appended so far, reported every few thousand.
        let totalFrames = max(1, plans.reduce(0) { $0 + $1.track.frames.count })
        var appendedFrames = 0
        let advance: (Int) -> Void = { count in
            appendedFrames += count
            progress?(min(1, Double(appendedFrames) / Double(totalFrames)))
        }

        var placed = 0
        for plan in plans {
            try Task.checkCancellation()
            let placement: Placement?
            switch plan.mapping {
            case .video(let description):
                placement = try appendVideo(plan.track, description: description, scale: scale, url: url,
                                            movie: movie, advance: advance)
            case .audio(let description, let timing, let audioStart):
                placement = try appendAudio(plan.track, description: description, timing: timing,
                                            start: audioStart, scale: scale, url: url, movie: movie,
                                            advance: advance)
            case .unsupported:
                placement = nil
            }
            guard let placement else {
                skipped.append(MatroskaSkippedTrack(number: plan.track.number, kind: plan.track.kindName,
                                                    codecID: plan.track.codecID,
                                                    reason: "its \(plan.track.kindName) track could not be added"))
                continue
            }
            let start = CMTime(value: (placement.startTicks - origin) * scale, timescale: 1_000_000_000) + placement.lead
            let target = CMTimeRange(start: start, duration: placement.mediaRange.duration)
            guard placement.track.insertMediaTimeRange(placement.mediaRange, into: target) else {
                movie.removeTrack(placement.track)
                skipped.append(MatroskaSkippedTrack(number: plan.track.number, kind: plan.track.kindName,
                                                    codecID: plan.track.codecID,
                                                    reason: "its \(plan.track.kindName) track could not be placed"))
                continue
            }

            let track = plan.track
            let isVideo = track.kind == .video
            let group = isVideo ? videoPlans.count : audioPlans.count
            if group > 1 {
                // One alternate group per media type: AVPlayer plays the
                // enabled member and offers the rest in its track menu.
                placement.track.alternateGroupID = isVideo ? 2 : 1
                placement.track.isEnabled = track.number == (isVideo ? preferredVideo : preferredAudio)
            } else {
                placement.track.isEnabled = true
            }
            if let language = track.language {
                if language.count == 3, !language.contains("-") {
                    placement.track.languageCode = language
                } else {
                    placement.track.extendedLanguageTag = language
                }
            }
            placed += 1
        }
        guard placed > 0 else {
            throw MatroskaError.noPlayableTracks(skipped.map(\.reason))
        }

        let played = Set(plans.map(\.track.number)).subtracting(skipped.map(\.number))
        return MatroskaMovie(
            sourceURL: url,
            asset: movie,
            skippedTracks: skipped,
            isComplete: index.isComplete,
            videoTrackCount: videoPlans.filter { played.contains($0.track.number) }.count,
            audioTrackCount: audioPlans.filter { played.contains($0.track.number) }.count
        )
    }

    private struct Placement {
        let track: AVMutableMovieTrack
        let mediaRange: CMTimeRange
        /// Matroska timestamp, in ticks, at which the media range starts playing.
        let startTicks: Int64
        /// How much later than `startTicks` the media range is placed.
        var lead: CMTime = .zero
    }

    /// The track Matroska marks as the one to play: default and enabled,
    /// then merely enabled, then the first.
    private static func preferredTrack(_ tracks: [MatroskaTrack]) -> UInt64? {
        (tracks.first { $0.isDefault && $0.isEnabled } ?? tracks.first { $0.isEnabled } ?? tracks.first)?.number
    }

    // MARK: Video

    private static func appendVideo(_ track: MatroskaTrack, description: CMVideoFormatDescription,
                                    scale: Int64, url: URL, movie: AVMutableMovie,
                                    advance: (Int) -> Void) throws -> Placement? {
        guard let movieTrack = movie.addMutableTrack(withMediaType: .video, copySettingsFrom: nil, options: nil) else {
            return nil
        }
        // Keep Matroska's own tick when it divides a second evenly (1 ms by
        // default), so no timestamp is rounded twice.
        let (timescale, multiplier): (Int32, Int64) = {
            let perSecond = 1_000_000_000 / scale
            if 1_000_000_000 % scale == 0, perSecond <= Int64(Int32.max), perSecond >= 1 {
                return (Int32(perSecond), 1)
            }
            return (1_000_000_000, scale)
        }()
        movieTrack.timescale = timescale
        let reference = url as CFURL

        let frames = track.frames
        let count = frames.count
        let pts = frames.map { $0.timestamp * multiplier }
        // Matroska stores frames in decode order with presentation times
        // only. Decode times are the presentation times in sorted order,
        // shifted back just enough that no frame decodes after it shows,
        // which is exactly the reorder delay of a B-frame stream.
        let sorted = pts.sorted()
        var shift: Int64 = 0
        for i in 0..<count { shift = max(shift, sorted[i] - pts[i]) }

        let lastDuration: Int64 = {
            if let last = frames.last, last.blockDuration > 0 { return last.blockDuration * multiplier }
            if let ns = track.defaultDuration {
                return max(1, Int64(ns) * Int64(timescale) / 1_000_000_000)
            }
            if count >= 2 { return max(1, sorted[count - 1] - sorted[count - 2]) }
            return Int64(timescale) / 30
        }()

        var appended = 0
        var reported = 0
        for i in 0..<count {
            if i - reported >= 0x4000 {
                try Task.checkCancellation()
                advance(i - reported)
                reported = i
            }
            let frame = frames[i]
            let dts = sorted[i] - shift
            let duration = i + 1 < count ? max(1, sorted[i + 1] - sorted[i]) : lastDuration
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: duration, timescale: timescale),
                presentationTimeStamp: CMTime(value: pts[i], timescale: timescale),
                decodeTimeStamp: CMTime(value: dts, timescale: timescale)
            )
            var size = Int(frame.size)
            guard let buffer = referenceBuffer(description: description, url: reference, offset: frame.offset,
                                               timing: &timing, count: 1, sizes: &size, sizeCount: 1) else { continue }
            if !frame.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            try appendReferences(buffer, to: movieTrack)
            appended += 1
        }
        advance(count - reported)
        let range = movieTrack.mediaPresentationTimeRange
        guard appended > 0, range.duration > .zero else { return nil }
        movieTrack.naturalSize = CGSize(width: track.pixelWidth, height: track.pixelHeight)
        return Placement(track: movieTrack, mediaRange: range, startTicks: sorted[0] / multiplier)
    }

    // MARK: Audio

    private static func appendAudio(_ track: MatroskaTrack, description: CMAudioFormatDescription,
                                    timing: AudioPacketTiming, start: AudioStart, scale: Int64, url: URL,
                                    movie: AVMutableMovie, advance: (Int) -> Void) throws -> Placement? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let movieTrack = movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: nil, options: nil) else {
            return nil
        }
        let rate = Int64(asbd.mSampleRate.rounded())
        guard rate > 0, rate <= Int64(Int32.max) else { return nil }
        let timescale = Int32(rate)
        movieTrack.timescale = timescale
        let reference = url as CFURL

        let frames = track.frames
        let count = frames.count
        func samples(fromTicks ticks: Int64) -> Int64 {
            Int64((Double(ticks) * Double(scale) * Double(rate) / 1_000_000_000).rounded())
        }

        // Samples each packet decodes to.
        var durations = [Int64](repeating: 0, count: count)
        var nextBlockStart = [Int64](repeating: -1, count: count)
        var upcoming: Int64 = -1
        for i in stride(from: count - 1, through: 0, by: -1) {
            nextBlockStart[i] = upcoming
            if frames[i].laceIndex == 0 { upcoming = frames[i].timestamp }
        }
        for i in 0..<count {
            let frame = frames[i]
            switch timing {
            case .fixed(let n):
                durations[i] = n
            case .opus:
                durations[i] = opusPacketSamples(prefix: frame.prefix) ?? 960
            case .pcm(let bytesPerFrame):
                durations[i] = Int64(Int(frame.size) / max(1, bytesPerFrame))
            case .fromTimestamps(let granularity):
                if nextBlockStart[i] >= 0 {
                    let span = samples(fromTicks: nextBlockStart[i] - frame.timestamp) / Int64(max(1, frame.laceCount))
                    let rounded = (span + granularity / 2) / granularity * granularity
                    durations[i] = max(granularity, rounded)
                } else {
                    durations[i] = i > 0 ? durations[i - 1] : max(granularity, 1024)
                }
            }
        }

        // Lay packets end to end, except where the file has a real gap in
        // its audio (a dropped segment in a recording): there the previous
        // packet is stretched so later audio stays in sync with the video.
        let startSample = samples(fromTicks: frames[0].timestamp)
        var cursor = startSample
        var positions = [Int64](repeating: 0, count: count)
        for i in 0..<count {
            if frames[i].laceIndex == 0, i > 0 {
                let actual = samples(fromTicks: frames[i].timestamp)
                let gap = actual - cursor
                if gap > max(durations[i - 1] * 2, rate / 10) {
                    durations[i - 1] += gap
                    cursor += gap
                }
            }
            positions[i] = cursor
            cursor += max(1, durations[i])
        }

        let isPCM: Bool
        if case .pcm = timing { isPCM = true } else { isPCM = false }

        var appended = 0
        var i = 0
        var reported = 0
        while i < count {
            if i - reported >= 0x4000 {
                try Task.checkCancellation()
                advance(i - reported)
                reported = i
            }
            let buffer: CMSampleBuffer?
            if isPCM, case .pcm(let bytesPerFrame) = timing {
                let frame = frames[i]
                let sampleCount = Int(frame.size) / max(1, bytesPerFrame)
                var timingInfo = CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: timescale),
                    presentationTimeStamp: CMTime(value: positions[i], timescale: timescale),
                    decodeTimeStamp: .invalid
                )
                var size = bytesPerFrame
                buffer = sampleCount > 0
                    ? referenceBuffer(description: description, url: reference, offset: frame.offset,
                                      timing: &timingInfo, count: sampleCount, sizes: &size, sizeCount: 1)
                    : nil
                i += 1
            } else {
                // Laced frames are contiguous on disk and share one buffer.
                var end = i + 1
                while end < count, end - i < 64,
                      frames[end].offset == frames[end - 1].offset + Int64(frames[end - 1].size) {
                    end += 1
                }
                var timings = (i..<end).map { j in
                    CMSampleTimingInfo(
                        duration: CMTime(value: max(1, durations[j]), timescale: timescale),
                        presentationTimeStamp: CMTime(value: positions[j], timescale: timescale),
                        decodeTimeStamp: CMTime(value: positions[j], timescale: timescale)
                    )
                }
                var sizes = (i..<end).map { Int(frames[$0].size) }
                buffer = timings.withUnsafeMutableBufferPointer { timing in
                    sizes.withUnsafeMutableBufferPointer { size in
                        referenceBuffer(description: description, url: reference, offset: frames[i].offset,
                                        timings: timing.baseAddress!, timingCount: timing.count,
                                        count: end - i, sizes: size.baseAddress!, sizeCount: size.count)
                    }
                }
                i = end
            }
            guard let buffer else { continue }
            try appendReferences(buffer, to: movieTrack)
            appended += 1
        }
        advance(count - reported)
        let media = movieTrack.mediaPresentationTimeRange
        guard appended > 0, media.duration > .zero else { return nil }

        // CodecDelay (encoder priming, Opus pre-skip) is decoded but never
        // heard: Matroska plays each frame at its timestamp minus the delay.
        // Part of it may already be hidden by AVFoundation (see AudioStart).
        let codecDelay = track.codecDelay.map { Int64((Double($0) * Double(rate) / 1_000_000_000).rounded()) } ?? 0
        let trim: Int64
        let lead: Int64
        switch start {
        case .exact:
            (trim, lead) = (codecDelay, 0)
        case .decoderHides(let hidden):
            (trim, lead) = (max(0, codecDelay - hidden), 0)
        case .movieHidesPriming(let hidden):
            (trim, lead) = (max(0, codecDelay - hidden), max(0, hidden - codecDelay))
        }
        let skip = CMTime(value: trim, timescale: timescale)
        guard media.duration > skip else { return nil }
        let range = CMTimeRange(start: media.start + skip, duration: media.duration - skip)
        return Placement(track: movieTrack, mediaRange: range, startTicks: frames[0].timestamp,
                         lead: CMTime(value: lead, timescale: timescale))
    }

    // MARK: Sample references

    /// Deprecated for Swift in the macOS 27 SDK in favour of `append(_:)`,
    /// which takes a `CMReadySampleBuffer`: a buffer that carries data. A
    /// reference-only buffer carries none, and this form still documents
    /// exactly that case on every OS Latent supports (macOS 14 and later).
    private static func appendReferences(_ buffer: CMSampleBuffer, to track: AVMutableMovieTrack) throws {
        try track.append(buffer, decodeTime: nil, presentationTime: nil)
    }

    private static func referenceBuffer(description: CMFormatDescription, url: CFURL, offset: Int64,
                                        timing: inout CMSampleTimingInfo, count: Int,
                                        sizes: inout Int, sizeCount: Int) -> CMSampleBuffer? {
        withUnsafeMutablePointer(to: &timing) { timingPointer in
            withUnsafeMutablePointer(to: &sizes) { sizePointer in
                referenceBuffer(description: description, url: url, offset: offset,
                                timings: timingPointer, timingCount: 1,
                                count: count, sizes: sizePointer, sizeCount: sizeCount)
            }
        }
    }

    /// A sample buffer that carries no bytes, only a pointer to where they
    /// live: AVMutableMovieTrack records it as a sample reference instead of
    /// copying data (see `kCMSampleBufferAttachmentKey_SampleReferenceURL`).
    private static func referenceBuffer(description: CMFormatDescription, url: CFURL, offset: Int64,
                                        timings: UnsafeMutablePointer<CMSampleTimingInfo>, timingCount: Int,
                                        count: Int, sizes: UnsafeMutablePointer<Int>, sizeCount: Int) -> CMSampleBuffer? {
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: count,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: timings,
            sampleSizeEntryCount: sizeCount,
            sampleSizeArray: sizes,
            sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { return nil }
        CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_SampleReferenceURL,
                        value: url, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_SampleReferenceByteOffset,
                        value: NSNumber(value: offset), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        return buffer
    }
}
