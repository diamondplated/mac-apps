import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import XCTest

@testable import ScreenWren

/// Synthetic frames through the real encode pipeline. Nothing here records the screen.
final class RecordingPipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenWrenRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A BGRA frame: a solid background (`background` is RGB) with an optional white square.
    static func frame(width: Int, height: Int, background: (UInt8, UInt8, UInt8),
                      square: CGRect? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                let inSquare = square?.contains(CGPoint(x: x, y: y)) ?? false
                pixel[0] = inSquare ? 255 : background.2
                pixel[1] = inSquare ? 255 : background.1
                pixel[2] = inSquare ? 255 : background.0
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }

    /// Records `count` frames at 30 fps, each made by `make(index)`.
    func record(count: Int, width: Int, height: Int, limit: Double = RecordingLimits.maximumDuration,
                stopAfter: Double? = nil, make: (Int) throws -> CVPixelBuffer) async throws -> RecordingInfo {
        let writer = try RecordingWriter(url: directory.appendingPathComponent("master-\(UUID().uuidString).mov"),
                                         width: width, height: height, limit: limit, realTime: false)
        let start = CMTime(value: 1_000, timescale: 30) // Host-clock times never start at zero.
        for index in 0..<count {
            _ = writer.append(try make(index), at: start + CMTime(value: CMTimeValue(index), timescale: 30))
        }
        let stop = stopAfter.map { start + CMTime(seconds: $0, preferredTimescale: 600) }
        return try await writer.finish(at: stop)
    }

    /// A clip whose frames all differ: a square sweeping across the frame.
    func movingSquareClip(seconds: Double, width: Int, height: Int) async throws -> RecordingInfo {
        let count = Int(seconds * 30)
        return try await record(count: count, width: width, height: height, stopAfter: seconds) { index in
            let side = CGFloat(height) / 4
            let x = CGFloat(index) / CGFloat(count) * (CGFloat(width) - side)
            return try Self.frame(width: width, height: height, background: (40, 90, 200),
                                  square: CGRect(x: x, y: CGFloat(height) / 3, width: side, height: side))
        }
    }

    /// A clip whose frame `i` has a solid colour that identifies it.
    func numberedClip(seconds: Double, width: Int = 64, height: Int = 48) async throws -> RecordingInfo {
        try await record(count: Int(seconds * 30), width: width, height: height, stopAfter: seconds) { index in
            try Self.frame(width: width, height: height, background: Self.colour(forFrame: index))
        }
    }

    static func colour(forFrame index: Int) -> (UInt8, UInt8, UInt8) {
        (UInt8((index % 30) * 8), UInt8((index / 30) * 100), 128)
    }

    /// `firstFrame` is the decoded pixel at the centre of the first frame, as stored: the
    /// video is tagged sRGB, so these are the values a player shows.
    func videoFacts(_ url: URL) async throws -> (duration: Double, frames: Int, size: CGSize, firstFrame: (Int, Int, Int)?) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var frames = 0
        var first: (Int, Int, Int)?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if first == nil {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let pixel = base + CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
                    + CVPixelBufferGetWidth(buffer) / 2 * 4
                first = (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            frames += 1
        }
        return (duration, frames, size, first)
    }

    func gifFacts(_ url: URL) throws -> (frames: Int, duration: Double, size: CGSize, source: CGImageSource) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        let count = CGImageSourceGetCount(source)
        var duration = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (count, duration, CGSize(width: width, height: height), source)
    }

    /// The sRGB value at (x, y), counted from the top left as GIF stores it.
    func rgb(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func assertClose(_ actual: (Int, Int, Int), _ expected: (UInt8, UInt8, UInt8), tolerance: Int,
                     _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(actual.0 - Int(expected.0)), tolerance, "red \(message) \(actual)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - Int(expected.1)), tolerance, "green \(message) \(actual)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - Int(expected.2)), tolerance, "blue \(message) \(actual)", file: file, line: line)
    }

    // MARK: - Tests

    func testRecordingWriterKeepsEveryFrameAndLastsUntilStop() async throws {
        let recording = try await record(count: 45, width: 64, height: 48, stopAfter: 2.0) { _ in
            try Self.frame(width: 64, height: 48, background: (10, 20, 30))
        }
        XCTAssertEqual(recording.duration, 2.0, accuracy: 0.01, "A screen that stops changing still lasts until Stop")
        let facts = try await videoFacts(recording.url)
        XCTAssertEqual(facts.duration, 2.0, accuracy: 0.04)
        XCTAssertEqual(facts.frames, 45)
        XCTAssertEqual(facts.size, CGSize(width: 64, height: 48))
    }

    func testRecordingStopsAtTheLimit() async throws {
        XCTAssertEqual(RecordingLimits.maximumDuration, 300, "Recordings are capped at five minutes")
        XCTAssertEqual(RecordingLimits.frameRate, 30)
        let writer = try RecordingWriter(url: directory.appendingPathComponent("limit.mov"), width: 32, height: 32,
                                         limit: 1, realTime: false)
        let frame = try Self.frame(width: 32, height: 32, background: (0, 0, 0))
        var results: [RecordingWriter.AppendResult] = []
        for index in 0..<45 { results.append(writer.append(frame, at: CMTime(value: CMTimeValue(index), timescale: 30))) }
        XCTAssertEqual(results.prefix(30).filter { $0 == .appended }.count, 30)
        XCTAssertTrue(results.dropFirst(30).allSatisfy { $0 == .reachedLimit }, "Nothing past the limit is written")
        let info = try await writer.finish(at: CMTime(seconds: 10, preferredTimescale: 600))
        XCTAssertEqual(info.duration, 1, accuracy: 0.01, "Stopping late never makes it longer than the limit")
        let facts = try await videoFacts(info.url)
        XCTAssertEqual(facts.duration, 1, accuracy: 0.04)
        XCTAssertEqual(facts.frames, 30)
    }

    func testAnEmptyRecordingFailsAndLeavesNoFile() async throws {
        let url = directory.appendingPathComponent("empty.mov")
        let writer = try RecordingWriter(url: url, width: 32, height: 32, realTime: false)
        do {
            _ = try await writer.finish(at: nil)
            XCTFail("An empty recording must fail")
        } catch RecordingError.noFrames {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMP4ExportIsReadableWithTheChosenSizeDurationAndFrames() async throws {
        let recording = try await movingSquareClip(seconds: 2, width: 320, height: 240)
        let url = directory.appendingPathComponent("out.mp4")
        var options = RecordingExportOptions()
        options.size = .half
        try await exportRecording(recording, trim: RecordingTrim(start: 0, end: recording.duration), options: options,
                                  to: url)
        let facts = try await videoFacts(url)
        XCTAssertEqual(facts.size, CGSize(width: 160, height: 120))
        XCTAssertEqual(facts.duration, 2, accuracy: 0.04)
        XCTAssertEqual(facts.frames, 60)
    }

    func testGIFExportIsReadableWithTheChosenSizeDurationAndFrames() async throws {
        let recording = try await movingSquareClip(seconds: 2, width: 200, height: 150)
        let url = directory.appendingPathComponent("out.gif")
        var options = RecordingExportOptions()
        options.format = .gif
        options.gifFrameRate = 15
        try await exportRecording(recording, trim: RecordingTrim(start: 0, end: recording.duration), options: options,
                                  to: url)
        let facts = try gifFacts(url)
        XCTAssertEqual(facts.size, CGSize(width: 200, height: 150))
        XCTAssertEqual(facts.frames, 30, "Every frame of a moving clip is kept at 15 fps")
        XCTAssertEqual(facts.duration, 2, accuracy: 0.011)
        // ImageIO composites the differenced frames; the square must be where it was drawn.
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(facts.source, facts.frames - 1, nil))
        XCTAssertEqual(last.width, 200)
        // GIF frame 29 starts at 1.933 s, when source frame 58 of 60 is showing.
        let side = 150.0 / 4
        let squareX = Int(58.0 / 60 * (200 - side) + side / 2)
        assertClose(try rgb(last, x: squareX, y: Int(50 + side / 2)), (255, 255, 255), tolerance: 24, "square")
        assertClose(try rgb(last, x: Int(28.0 / 60 * (200 - side) + side / 2), y: Int(50 + side / 2)), (40, 90, 200),
                    tolerance: 24, "where the square was earlier")
        assertClose(try rgb(last, x: 5, y: 5), (40, 90, 200), tolerance: 24, "background")
    }

    func testGIFDifferencingMergesStillFramesWithoutChangingTheLength() async throws {
        // 1 s of one picture, then 1 s of another: two frames are enough.
        let recording = try await record(count: 60, width: 80, height: 60, stopAfter: 2) { index in
            try Self.frame(width: 80, height: 60, background: index < 30 ? (200, 30, 30) : (30, 200, 30))
        }
        let url = directory.appendingPathComponent("still.gif")
        try await exportRecordingGIF(source: recording.url, trim: RecordingTrim(start: 0, end: 2),
                                     width: 80, height: 60, frameRate: 20, to: url)
        let facts = try gifFacts(url)
        XCTAssertEqual(facts.frames, 2, "Unchanged frames are not written again")
        XCTAssertEqual(facts.duration, 2, accuracy: 0.011)
        let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(facts.source, 1, nil))
        assertClose(try rgb(second, x: 40, y: 30), (30, 200, 30), tolerance: 16)
    }

    func testTrimKeepsExactlyTheChosenRange() async throws {
        let recording = try await numberedClip(seconds: 3)
        let trim = RecordingTrim(start: 1, end: 2)

        let mp4 = directory.appendingPathComponent("trim.mp4")
        try await exportRecording(recording, trim: trim, options: RecordingExportOptions(), to: mp4)
        let video = try await videoFacts(mp4)
        XCTAssertEqual(video.duration, 1, accuracy: 0.04)
        XCTAssertEqual(video.frames, 30)
        assertClose(try XCTUnwrap(video.firstFrame), Self.colour(forFrame: 30),
                    tolerance: 6, "the first MP4 frame is source frame 30")

        let gif = directory.appendingPathComponent("trim.gif")
        var options = RecordingExportOptions()
        options.format = .gif
        options.gifFrameRate = 10
        try await exportRecording(recording, trim: trim, options: options, to: gif)
        let animation = try gifFacts(gif)
        XCTAssertEqual(animation.duration, 1, accuracy: 0.011)
        XCTAssertEqual(animation.frames, 10)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(animation.source, 0, nil))
        assertClose(try rgb(first, x: 32, y: 24), Self.colour(forFrame: 30), tolerance: 10,
                    "the first GIF frame is source frame 30")
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(animation.source, animation.frames - 1, nil))
        assertClose(try rgb(last, x: 32, y: 24), Self.colour(forFrame: 57), tolerance: 10,
                    "the last GIF frame is source frame 57, the one showing at 1.9 s")
    }

    func testTrimClampsToTheRecordingAndAMinimumLength() {
        XCTAssertEqual(RecordingTrim.clamped(start: -1, end: 9, duration: 4), RecordingTrim(start: 0, end: 4))
        XCTAssertEqual(RecordingTrim.clamped(start: 3, end: 2, duration: 4), RecordingTrim(start: 3, end: 3.2))
        XCTAssertEqual(RecordingTrim.clamped(start: 3.95, end: 4, duration: 4), RecordingTrim(start: 3.8, end: 4))
        XCTAssertEqual(RecordingTrim.clamped(start: .nan, end: .infinity, duration: 2), RecordingTrim(start: 0, end: 2))
    }

    func testOutputSizesNeverUpscaleAndKeepMP4Even() {
        func size(_ option: RecordingOutputSize, _ format: RecordingFormat) -> [Int] {
            let value = recordingOutputPixelSize(sourceWidth: 1601, sourceHeight: 1201, size: option, format: format)
            return [value.width, value.height]
        }
        XCTAssertEqual(size(.original, .gif), [1601, 1201])
        XCTAssertEqual(size(.original, .mp4), [1600, 1200])
        XCTAssertEqual(size(.half, .gif), [800, 600])
        XCTAssertEqual(size(.width(640), .mp4), [640, 480])
        XCTAssertEqual(size(.width(5_000), .gif), [1601, 1201], "A chosen width never upscales")
        XCTAssertEqual(size(.width(1), .gif)[0], RecordingExportOptions.minimumWidth)
        let stream = recordingStreamPixelSize(points: CGSize(width: 400.5, height: 301), scale: 2)
        XCTAssertEqual([stream.width, stream.height], [800, 602])
    }

    func testGIFFrameTimesAndDelaysAddUpExactly() {
        let times = gifFrameTimes(duration: 1, frameRate: 15)
        XCTAssertEqual(times.count, 15)
        let delays = zip(times, times.dropFirst().map { $0 } + [1]).map { gifCentiseconds($1) - gifCentiseconds($0) }
        XCTAssertEqual(delays.reduce(0, +), 100, "15 fps has no whole-centisecond delay, but the total is exact")
        XCTAssertEqual(gifFrameTimes(duration: 0.25, frameRate: 10).count, 3)
        XCTAssertTrue(gifFrameTimes(duration: 0, frameRate: 10).isEmpty)
    }

    func testExportOptionsAreRememberedInScreenWrensOwnPreferences() throws {
        let name = "ScreenWrenTests.Recording.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RecordingExportOptions.load(from: defaults), RecordingExportOptions())
        let chosen = RecordingExportOptions(format: .gif, size: .width(720), gifFrameRate: 20)
        chosen.save(to: defaults)
        XCTAssertEqual(RecordingExportOptions.load(from: defaults), chosen)
        defaults.set(13, forKey: "recording.gifFrameRate")
        XCTAssertEqual(RecordingExportOptions.load(from: defaults).gifFrameRate, 15, "Only 10, 15 or 20 fps")
    }

    func testTemporaryFoldersOfOtherRunningCopiesSurvive() throws {
        let root = directory.appendingPathComponent("root", isDirectory: true)
        for name in ["111", "222", "junk", String(getpid())] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        RecordingFiles.removeStale(root: root) { $0 == 222 }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, ["222", String(getpid())].sorted())
        RecordingFiles.removeProcessDirectory(root: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["222"])
    }

    /// The figures quoted in the PR: a 5-second 800×600 clip. Opt in, it takes a few seconds.
    func testMeasureFiveSecondClip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENWREN_MEASURE_RECORDING"] == "1")
        let clips = [
            ("square", try await movingSquareClip(seconds: 5, width: 800, height: 600)),
            ("scrolling-text", try await scrollingTextClip(seconds: 5, width: 800, height: 600)),
        ]
        for (name, recording) in clips {
            for format in RecordingFormat.allCases {
                let url = directory.appendingPathComponent("measure-\(name).\(format.fileExtension)")
                var options = RecordingExportOptions()
                options.format = format
                let started = Date()
                try await exportRecording(recording, trim: RecordingTrim(start: 0, end: 5), options: options, to: url)
                let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                print("SCREENWREN_MEASURE \(name) \(format.rawValue) 800x600 5s: \(bytes) bytes in "
                      + String(format: "%.1f s", Date().timeIntervalSince(started)))
            }
        }
    }

    /// A busier, UI-like clip: rows of dark text on white scrolling up 4 pixels a frame.
    func scrollingTextClip(seconds: Double, width: Int, height: Int) async throws -> RecordingInfo {
        try await record(count: Int(seconds * 30), width: width, height: height, stopAfter: seconds) { index in
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            let context = try XCTUnwrap(CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes2: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.15, alpha: 1),
            ]
            let offset = index * 4
            for row in 0..<40 {
                let y = height - 30 - row * 24 + offset % 24
                guard y > -24, y < height else { continue }
                let line = row + offset / 24
                ("Line \(line): the quick brown fox jumps over the lazy dog, \(line * 37 % 1000) items" as NSString)
                    .draw(at: CGPoint(x: 24, y: y), withAttributes: attributes2)
            }
            NSGraphicsContext.restoreGraphicsState()
            return pixelBuffer
        }
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
