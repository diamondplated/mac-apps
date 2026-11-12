import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Fixed limits for a region recording.
enum RecordingLimits {
    static let frameRate = 30
    /// A recording stops by itself after five minutes.
    static let maximumDuration: Double = 300
    /// The trim control never selects less than this.
    static let minimumTrimLength: Double = 0.2
}

enum RecordingError: LocalizedError {
    case noFrames
    case couldNotWrite(String)
    case couldNotRead(String)
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .noFrames: "The recording has no frames."
        case let .couldNotWrite(detail): "Couldn’t write the recording: \(detail)"
        case let .couldNotRead(detail): "Couldn’t read the recording: \(detail)"
        case .invalidSize: "That recording size isn’t possible."
        }
    }
}

/// A finished temporary recording.
struct RecordingInfo: Equatable, Sendable {
    let url: URL
    let width: Int
    let height: Int
    let duration: Double
}

/// The stream's pixel size for a region: the display scale, rounded down to even numbers
/// because H.264 works in 2×2 blocks.
func recordingStreamPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    func even(_ value: CGFloat) -> Int { max(2, Int((value * scale).rounded()) & ~1) }
    return (even(points.width), even(points.height))
}

// MARK: - Export options

enum RecordingFormat: String, CaseIterable, Sendable {
    case mp4, gif
    var title: String { self == .mp4 ? "MP4 (H.264)" : "GIF" }
    var fileExtension: String { rawValue }
}

enum RecordingOutputSize: Equatable, Sendable {
    case original
    case half
    case width(Int)
}

/// The review window's choices, remembered in ScreenWren's own preferences.
struct RecordingExportOptions: Equatable, Sendable {
    static let gifFrameRates = [10, 15, 20]
    static let minimumWidth = 16

    var format: RecordingFormat = .mp4
    var size: RecordingOutputSize = .original
    var gifFrameRate = 15

    static func load(from defaults: UserDefaults = .standard) -> Self {
        var options = Self()
        options.format = RecordingFormat(rawValue: defaults.string(forKey: "recording.format") ?? "") ?? .mp4
        switch defaults.string(forKey: "recording.size") {
        case "half": options.size = .half
        case "width":
            let width = defaults.integer(forKey: "recording.width")
            options.size = width >= minimumWidth ? .width(width) : .original
        default: options.size = .original
        }
        let rate = defaults.integer(forKey: "recording.gifFrameRate")
        options.gifFrameRate = gifFrameRates.contains(rate) ? rate : 15
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: "recording.format")
        switch size {
        case .original: defaults.set("original", forKey: "recording.size")
        case .half: defaults.set("half", forKey: "recording.size")
        case let .width(width):
            defaults.set("width", forKey: "recording.size")
            defaults.set(width, forKey: "recording.width")
        }
        defaults.set(gifFrameRate, forKey: "recording.gifFrameRate")
    }
}

/// The exported pixel size. Never larger than the recording; MP4 sizes are even.
func recordingOutputPixelSize(sourceWidth: Int, sourceHeight: Int, size: RecordingOutputSize,
                              format: RecordingFormat) -> (width: Int, height: Int) {
    guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
    let width: Int
    switch size {
    case .original: width = sourceWidth
    case .half: width = max(1, sourceWidth / 2)
    case let .width(requested): width = min(sourceWidth, max(RecordingExportOptions.minimumWidth, requested))
    }
    var height = max(1, Int((Double(width) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
    var finalWidth = width
    if format == .mp4 {
        finalWidth = max(2, finalWidth & ~1)
        height = max(2, height & ~1)
    }
    return (finalWidth, height)
}

/// The part of a recording to keep, in seconds, clamped to the recording and never
/// shorter than the minimum trim length.
struct RecordingTrim: Equatable, Sendable {
    var start: Double
    var end: Double
    var length: Double { end - start }

    static func clamped(start: Double, end: Double, duration: Double,
                        minimumLength: Double = RecordingLimits.minimumTrimLength) -> RecordingTrim {
        let duration = max(0, duration)
        let minimum = min(minimumLength, duration)
        var start = min(max(0, start.isFinite ? start : 0), max(0, duration - minimum))
        var end = min(max(0, end.isFinite ? end : duration), duration)
        if end - start < minimum {
            end = min(duration, start + minimum)
            start = max(0, end - minimum)
        }
        return RecordingTrim(start: start, end: end)
    }

    var timeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

/// The start time, in seconds from the trim start, of every GIF frame.
func gifFrameTimes(duration: Double, frameRate: Int) -> [Double] {
    guard duration > 0, frameRate > 0 else { return [] }
    let count = max(1, Int((duration * Double(frameRate) - 1e-6).rounded(.up)))
    return (0..<count).map { Double($0) / Double(frameRate) }
}

/// GIF delays are whole centiseconds. Rounding each frame's start rather than each delay
/// keeps the total length exact.
func gifCentiseconds(_ seconds: Double) -> Int { Int((seconds * 100).rounded()) }

func recordingFilename(for date: Date = Date(), format: RecordingFormat) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "ScreenWren Recording \(formatter.string(from: date)).\(format.fileExtension)"
}

// MARK: - Writing the temporary recording

/// Screen pixels are sRGB. Tagging the video as sRGB (709 primaries are sRGB's) keeps every
/// value as it was on screen instead of converting it to a camera transfer curve and back.
private var screenColorProperties: [String: Any] { [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
] }

/// Writes captured frames to the temporary recording. It is used from one queue at a time:
/// the stream's sample queue while recording, or the caller's thread in tests.
final class RecordingWriter: @unchecked Sendable {
    enum AppendResult: Equatable { case appended, dropped, reachedLimit }

    let url: URL
    let width: Int
    let height: Int
    let limit: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let waitsForInput: Bool
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private(set) var appendedFrames = 0

    init(url: URL, width: Int, height: Int, limit: Double = RecordingLimits.maximumDuration,
         realTime: Bool = true) throws {
        guard width >= 2, height >= 2, width <= 16_384, height <= 16_384 else { throw RecordingError.invalidSize }
        self.url = url
        self.width = width
        self.height = height
        self.limit = limit
        waitsForInput = !realTime
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // A generous bitrate: this file is the source for every export, not the export itself.
        let bitrate = min(60_000_000, max(6_000_000, width * height * RecordingLimits.frameRate / 5))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: screenColorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: RecordingLimits.frameRate,
                AVVideoMaxKeyFrameIntervalKey: RecordingLimits.frameRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = realTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecordingError.couldNotWrite("unsupported video settings") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecordingError.couldNotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime) -> AppendResult {
        guard writer.status == .writing, time.isNumeric else { return .dropped }
        let start: CMTime
        if let startTime {
            start = startTime
        } else {
            writer.startSession(atSourceTime: time)
            startTime = time
            start = time
        }
        if (time - start).seconds >= limit { return .reachedLimit }
        if let lastTime, time <= lastTime { return .dropped }
        if !input.isReadyForMoreMediaData {
            guard waitsForInput else { return .dropped }
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                usleep(1_000)
            }
            guard input.isReadyForMoreMediaData else { return .dropped }
        }
        tagAsSRGBIfUntagged(buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { return .dropped }
        lastTime = time
        appendedFrames += 1
        return .appended
    }

    /// Ends the recording at `stopTime` (a time on the same clock as the frames), so a
    /// screen that stopped changing still lasts until Stop. Never past the limit.
    func finish(at stopTime: CMTime?, completion: @escaping @Sendable (Result<RecordingInfo, Error>) -> Void) {
        guard let startTime, let lastTime, appendedFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(RecordingError.noFrames))
            return
        }
        let frame = CMTime(value: 1, timescale: CMTimeScale(RecordingLimits.frameRate))
        var end = lastTime + frame
        if let stopTime, stopTime.isNumeric, stopTime > end { end = stopTime }
        let cap = startTime + CMTime(seconds: limit, preferredTimescale: 600)
        if end > cap { end = max(cap, lastTime + CMTime(value: 1, timescale: 600)) }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        let info = RecordingInfo(url: url, width: width, height: height, duration: (end - startTime).seconds)
        nonisolated(unsafe) let unsafeWriter = writer
        writer.finishWriting {
            if unsafeWriter.status == .completed {
                completion(.success(info))
            } else {
                completion(.failure(RecordingError.couldNotWrite(
                    unsafeWriter.error?.localizedDescription ?? "unknown error")))
            }
        }
    }

    func finish(at stopTime: CMTime?) async throws -> RecordingInfo {
        try await withCheckedThrowingContinuation { continuation in
            finish(at: stopTime) { continuation.resume(with: $0) }
        }
    }
}

/// The stream is configured for sRGB. A frame without colour tags would be encoded as if it
/// were already in the video's transfer function and come back too bright, so say what it is.
func tagAsSRGBIfUntagged(_ buffer: CVPixelBuffer) {
    guard CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) == nil else { return }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB,
                          .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          .shouldPropagate)
    if let space = CGColorSpace(name: CGColorSpace.sRGB) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
    }
}

// MARK: - Export

private struct SendableBuffer: @unchecked Sendable { let buffer: CVPixelBuffer }

/// Reads the trimmed part of a recording frame by frame, retimed to start at zero.
private func readFrames(of source: URL, trim: RecordingTrim, pixelFormat: OSType,
                        _ body: (CVPixelBuffer, CMTime) throws -> Void) async throws {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw RecordingError.couldNotRead("no video track")
    }
    let reader = try AVAssetReader(asset: asset)
    let range = trim.timeRange
    reader.timeRange = range
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw RecordingError.couldNotRead("unsupported track") }
    reader.add(output)
    guard reader.startReading() else {
        throw RecordingError.couldNotRead(reader.error?.localizedDescription ?? "unknown error")
    }
    defer { if reader.status == .reading { reader.cancelReading() } }
    // The frame showing at the trim start may begin before it. Hold each frame until the
    // next one shows whether it is still the latest one at or before the start.
    var held: (CVPixelBuffer, CMTime)?
    while let sample = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample) - range.start
        guard time < range.duration else { break }
        if let pending = held {
            if time <= .zero {
                held = (buffer, .zero)
                continue
            }
            try body(pending.0, max(pending.1, .zero))
        }
        held = (buffer, max(time, .zero))
    }
    if reader.status == .failed {
        throw RecordingError.couldNotRead(reader.error?.localizedDescription ?? "unknown error")
    }
    if let pending = held { try body(pending.0, pending.1) }
}

/// Exports the trimmed recording as an H.264 MP4 of the given size.
func exportRecordingMP4(source: URL, trim: RecordingTrim, width: Int, height: Int, to destination: URL) async throws {
    guard width >= 2, height >= 2 else { throw RecordingError.invalidSize }
    try? FileManager.default.removeItem(at: destination)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    // Screen content is mostly flat and still; this bitrate keeps text sharp without
    // the file sizes of a general-purpose recorder.
    let bitrate = min(16_000_000, max(400_000, Int(Double(width * height * RecordingLimits.frameRate) * 0.09)))
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoColorPropertiesKey: screenColorProperties,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: RecordingLimits.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 4,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    guard writer.canAdd(input) else { throw RecordingError.couldNotWrite("unsupported video settings") }
    writer.add(input)
    guard writer.startWriting() else {
        throw RecordingError.couldNotWrite(writer.error?.localizedDescription ?? "unknown error")
    }
    writer.startSession(atSourceTime: .zero)
    do {
        try await readFrames(of: source, trim: trim, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            buffer, time in
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { break }
                try Task.checkCancellation()
                usleep(1_000)
            }
            // Decoded frames don't always carry the source's tags; the source is always sRGB.
            tagAsSRGBIfUntagged(buffer)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw RecordingError.couldNotWrite(writer.error?.localizedDescription ?? "frame rejected")
            }
        }
    } catch {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: trim.length, preferredTimescale: 600))
    nonisolated(unsafe) let unsafeWriter = writer
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        unsafeWriter.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        try? FileManager.default.removeItem(at: destination)
        throw RecordingError.couldNotWrite(writer.error?.localizedDescription ?? "unknown error")
    }
}

/// An RGBX canvas that frames are scaled into before quantising.
private final class GIFCanvas {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw RecordingError.invalidSize }
        context.interpolationQuality = .high
        self.context = context
    }

    /// Draws a decoded BGRA frame. Its bytes are sRGB values (the video is tagged sRGB), so
    /// they are read as sRGB directly; a video ICC profile would shift them.
    func draw(_ buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let frame = CGContext(data: base, width: CVPixelBufferGetWidth(buffer),
                                    height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = frame.makeImage()
        else { throw RecordingError.couldNotRead("undecodable frame") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var pixels: UnsafePointer<UInt8> { UnsafePointer(context.data!.assumingMemoryBound(to: UInt8.self)) }
    var bytesPerRow: Int { context.bytesPerRow }
}

/// Visits the source frame showing at each GIF frame time.
private func forEachGIFFrame(source: URL, trim: RecordingTrim, times: [Double],
                             _ body: (Int, CVPixelBuffer) throws -> Void) async throws {
    var next = 0
    var current: CVPixelBuffer?
    try await readFrames(of: source, trim: trim, pixelFormat: kCVPixelFormatType_32BGRA) { buffer, time in
        let seconds = time.seconds
        while next < times.count, times[next] < seconds - 1e-6 {
            if let current { try body(next, current) }
            next += 1
        }
        current = buffer
    }
    while next < times.count, let current {
        try body(next, current)
        next += 1
    }
}

/// Exports the trimmed recording as a looping GIF: one palette built from frames across the
/// whole clip, then only the changed rectangle of each frame.
func exportRecordingGIF(source: URL, trim: RecordingTrim, width: Int, height: Int, frameRate: Int,
                        to destination: URL) async throws {
    guard width >= 1, height >= 1, width <= 8_192, height <= 8_192 else { throw RecordingError.invalidSize }
    let times = gifFrameTimes(duration: trim.length, frameRate: frameRate)
    guard !times.isEmpty else { throw RecordingError.noFrames }
    let canvas = try GIFCanvas(width: width, height: height)

    // Pass 1: a palette from up to 24 frames spread across the clip, about 400k pixels.
    var builder = GIFPaletteBuilder()
    let sampledFrames = Set(stride(from: 0, to: times.count, by: max(1, times.count / 24)))
    let step = max(1, Int((Double(width * height * sampledFrames.count) / 400_000).squareRoot()))
    try await forEachGIFFrame(source: source, trim: trim, times: times) { index, buffer in
        guard sampledFrames.contains(index) else { return }
        try canvas.draw(buffer)
        builder.add(rgbx: canvas.pixels, width: width, height: height, bytesPerRow: canvas.bytesPerRow, step: step)
    }
    let mapper = GIFColorMapper(palette: builder.build())

    // Pass 2: every frame, quantised to that palette and differenced against the last.
    let writer = GIFAnimationWriter(width: width, height: height, palette: mapper.palette)
    try await forEachGIFFrame(source: source, trim: trim, times: times) { index, buffer in
        try canvas.draw(buffer)
        var indices = mapper.indices(rgbx: canvas.pixels, width: width, height: height,
                                     bytesPerRow: canvas.bytesPerRow)
        if let shown = writer.canvas {
            gifKeepUnchangedPixels(&indices, shown: shown, rgbx: canvas.pixels, width: width, height: height,
                                   bytesPerRow: canvas.bytesPerRow, palette: mapper.palette)
        }
        writer.addFrame(indices, start: gifCentiseconds(times[index]))
    }
    let data = writer.finish(end: gifCentiseconds(trim.length))
    try Task.checkCancellation()
    try data.write(to: destination, options: .atomic)
}

/// Exports with the chosen options; the file lands at `destination`.
func exportRecording(_ recording: RecordingInfo, trim: RecordingTrim, options: RecordingExportOptions,
                     to destination: URL) async throws {
    let size = recordingOutputPixelSize(sourceWidth: recording.width, sourceHeight: recording.height,
                                        size: options.size, format: options.format)
    switch options.format {
    case .mp4:
        try await exportRecordingMP4(source: recording.url, trim: trim, width: size.width, height: size.height,
                                     to: destination)
    case .gif:
        try await exportRecordingGIF(source: recording.url, trim: trim, width: size.width, height: size.height,
                                     frameRate: options.gifFrameRate, to: destination)
    }
}

// MARK: - Temporary files

/// Every recording file ScreenWren makes lives under one folder per running process in the
/// user's temporary directory. A review window deletes its own folder when it closes, the
/// whole process folder goes when ScreenWren quits, and folders left by a process that no
/// longer exists are removed at the next launch.
enum RecordingFiles {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScreenWren Recordings", isDirectory: true)
    }

    static func processDirectory(root: URL = root, processID: pid_t = getpid()) -> URL {
        root.appendingPathComponent(String(processID), isDirectory: true)
    }

    static func makeSessionDirectory(root: URL = root) throws -> URL {
        let directory = processDirectory(root: root).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func clipboardDirectory(root: URL = root) throws -> URL {
        let directory = processDirectory(root: root).appendingPathComponent("Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeProcessDirectory(root: URL = root) {
        try? FileManager.default.removeItem(at: processDirectory(root: root))
    }

    /// Removes folders of processes that are gone, never those of a running copy.
    static func removeStale(root: URL = root, isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            guard let processID = pid_t(entry.lastPathComponent) else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            if processID != getpid(), !isRunning(processID) { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
