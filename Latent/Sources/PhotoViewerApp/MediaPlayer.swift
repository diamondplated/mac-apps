import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO
import os
import PhotoContainers

/// What kind of media a URL is, so DetailView knows whether to draw a
/// CGImage, animate an NSImageView, or hand it to AVPlayer.
enum MediaKind: Sendable, Equatable {
    case staticImage
    case animatedImage   // GIF, animated PNG, animated HEIC/AVIF/WebP
    case video
    case unsupported
}

enum MediaTyping {
    /// Static image extensions our pipeline already handles.
    static let staticImageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "bmp",
        // RAW formats ImageIO can preview via their embedded JPEG.
        "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2",
    ]
    /// Containers commonly used for animated single-file content. We still
    /// inspect frame count via CGImageSource at runtime — a static .png
    /// stays in the static path even though .png is also in this list,
    /// because `detect()` falls through to `.staticImage` if frameCount == 1.
    static let possiblyAnimatedExts: Set<String> = [
        "gif", "png", "heic", "heif", "webp", "avif",
    ]
    /// Video container extensions whose UTIs AVFoundation reports as
    /// audiovisual types on macOS, plus Matroska and AVI, which
    /// PhotoContainers reads for it. Keep this explicit instead
    /// of accepting every `public.movie` subtype: AVPlayer does not provide a
    /// stock WebM/FLV/WMV/Ogg demuxer, even when VideoToolbox can decode a
    /// codec carried by one of those containers.
    ///
    /// A recognized container can still contain an unsupported codec. In that
    /// case AVPlayer owns the playback failure and presents its normal error.
    static let videoExts: Set<String> = Set([
        "mp4", "mpg4", "mov", "qt", "m4v",
        "3gp", "3gpp", "sdv", "3g2", "3gp2",
        "mts", "m2ts",
        "mpg", "mpeg", "mpe", "m75", "m15", "m2v", "ts",
        "dv", "dif",
    ]).union(indexedExts)

    /// AVFoundation has no Matroska or AVI demuxer; PhotoContainers indexes
    /// these and hands AVPlayer a movie that reads the original file in place.
    static let indexedExts: Set<String> = ["mkv", "avi", "vfw"]

    static func needsIndexing(_ url: URL) -> Bool {
        indexedExts.contains(url.pathExtension.lowercased())
    }

    /// AVFoundation itself opens some AVIs (Motion JPEG and plain audio, as
    /// cameras and voice recorders write them). When the AVI reader can't
    /// make sense of one, those still play the way they did before it.
    static func nativeAVI(_ url: URL) async -> AVAsset? {
        guard ["avi", "vfw"].contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return nil }
        return asset
    }

    static var allMediaExts: Set<String> {
        staticImageExts.union(possiblyAnimatedExts).union(videoExts)
    }

    /// Classify a URL. Cheap (extension check + at most one
    /// CGImageSourceCreate for animated detection).
    static func detect(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) { return .video }
        if possiblyAnimatedExts.contains(ext) {
            // Real frame count check — a .gif might be a single frame, an
            // .png is usually static. Don't burn a decode if we can avoid it.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               CGImageSourceGetCount(src) > 1 {
                return .animatedImage
            }
            return .staticImage
        }
        if staticImageExts.contains(ext) { return .staticImage }
        return .unsupported
    }
}

// MARK: - Video keyboard routing

/// Commands the window-level key monitor can send to the currently visible
/// video without relying on AppKit first-responder focus. `AVPlayerView` only
/// receives key events after it has been clicked; keeping this tiny weak
/// registry lets keyboard playback work immediately after j/k navigation while
/// still leaving every unrelated key with the native responder chain.
@MainActor
final class VideoPlaybackRouter {
    static let shared = VideoPlaybackRouter()

    private weak var playerView: AVPlayerView?
    private var representedURL: URL?

    private init() {}

    func register(_ playerView: AVPlayerView, url: URL) {
        self.playerView = playerView
        representedURL = url
    }

    func unregister(_ playerView: AVPlayerView) {
        guard self.playerView === playerView else { return }
        self.playerView = nil
        representedURL = nil
    }

    /// Returns true only when the command was delivered to the player that is
    /// displaying `url`. The URL check prevents a retiring representable from
    /// receiving a key during a rapid selection change.
    @discardableResult
    func handle(keyCode: UInt16, for url: URL) -> Bool {
        guard representedURL == url,
              let player = playerView?.player else { return false }

        switch keyCode {
        case 49: // Space — play / pause
            if player.timeControlStatus == .paused {
                restartIfAtEnd(player)
                player.play()
            } else {
                player.pause()
            }
        case 123: // Left — five seconds back
            seek(player, by: -5)
        case 124: // Right — five seconds forward
            seek(player, by: 5)
        case 125: // Down — volume down
            player.volume = max(0, player.volume - 0.05)
        case 126: // Up — volume up
            player.volume = min(1, player.volume + 0.05)
        default:
            return false
        }
        return true
    }

    private func seek(_ player: AVPlayer, by delta: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }

        var target = max(0, current + delta)
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite {
            target = min(target, duration)
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func restartIfAtEnd(_ player: AVPlayer) {
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard current.isFinite, duration.isFinite, duration > 0,
              current >= duration - 0.05 else { return }
        player.seek(to: .zero)
    }
}

// MARK: - Animated image view

/// SwiftUI wrapper around `NSImageView` so animated GIF / APNG / animated
/// HEIC/WebP/AVIF play without us having to write our own frame stepper.
/// NSImageView's `animates = true` cycles frames at the rate baked into the
/// file (loop count + per-frame delays).
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyDown
        v.animates = true
        v.canDrawSubviewsIntoLayer = true
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Re-load on URL change. NSImage(contentsOf:) detects the multi-
        // frame representation and NSImageView animates it once attached.
        let new = NSImage(contentsOf: url)
        if nsView.image != new {
            nsView.image = new
            nsView.animates = true
        }
    }
}

// MARK: - Video view

/// The detail pane's player for any video Latent lists: Matroska and AVI
/// files are indexed first, everything else goes straight to AVPlayer.
struct VideoContentView: View {
    let url: URL

    var body: some View {
        if MediaTyping.needsIndexing(url) {
            IndexedMoviePlaybackView(url: url)
        } else {
            VideoPlaybackView(url: url)
        }
    }
}

/// SwiftUI wrapper around AVKit's `AVPlayerView`. Auto-plays on appear,
/// pauses on disappear. Handles the format set AVFoundation supports
/// natively. Container recognition does not guarantee that every codec inside
/// the container is installed; AVPlayer presents its normal playback error
/// for those files.
struct VideoPlaybackView: NSViewRepresentable {
    let url: URL
    /// A prepared asset for a container AVFoundation cannot open by URL
    /// (Matroska, AVI). Nil plays `url` directly.
    var asset: AVAsset?

    final class Coordinator {
        var playing: (url: URL, asset: ObjectIdentifier?)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let identity = asset.map(ObjectIdentifier.init)
        let current = context.coordinator.playing
        if nsView.player == nil || current?.url != url || current?.asset != identity {
            let item = asset.map { AVPlayerItem(asset: $0) } ?? AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            nsView.player = player
            context.coordinator.playing = (url, identity)
            // Auto-play on selection — viewer behavior, not media-app behavior.
            // The user can still pause from the controls.
            player.play()
        }
        VideoPlaybackRouter.shared.register(nsView, url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        VideoPlaybackRouter.shared.unregister(nsView)
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - Matroska and AVI

/// Plays an `.mkv` or `.avi`. Indexing reads the whole file once (an AVI
/// with an index only its headers and index; H.264 in AVI is also copied
/// into a scratch file), which is instant on a local disk and can take a
/// while for a long recording on a network volume, so it shows progress, and
/// leaving the file cancels it.
struct IndexedMoviePlaybackView: View {
    let url: URL

    private enum Phase {
        case loading(Double)
        case ready(ReferenceMovie)
        /// An AVI the reader failed on that AVFoundation opens itself.
        case native(AVAsset)
        case failed(String)
    }

    @State private var phase: Phase = .loading(0)
    @State private var showsProgress = false

    var body: some View {
        Group {
            switch phase {
            case .loading(let fraction):
                if showsProgress {
                    VStack(spacing: 10) {
                        ProgressView(value: fraction)
                            .frame(width: 220)
                        Text("Reading \(url.lastPathComponent)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            case .ready(let movie):
                VideoPlaybackView(url: url, asset: movie.asset)
                    .overlay(alignment: .top) {
                        if let note = Self.note(for: movie) {
                            // Reasons run long; wrap them below the
                            // detail pane's file name badge.
                            Text(note)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Theme.shape(Theme.Radius.card))
                                .frame(maxWidth: 460)
                                .padding(.horizontal, 16)
                                .padding(.top, 52)
                                .allowsHitTesting(false)
                        }
                    }
            case .native(let asset):
                VideoPlaybackView(url: url, asset: asset)
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Can't play this video")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Text(url.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { await load() }
        .task(id: url) {
            // Small files open before a progress bar would be worth drawing.
            showsProgress = false
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsProgress = true }
        }
    }

    private func load() async {
        phase = .loading(0)
        let reporter = ProgressRelay { fraction in
            // A late update must not pull a finished load back to loading.
            if case .loading = phase { phase = .loading(fraction) }
        }
        do {
            let movie = try await ReferenceMovie.open(url: url) { fraction in
                reporter.send(fraction)
            }
            guard !Task.isCancelled else { return }
            phase = .ready(movie)
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? ContainerError)?.description ?? error.localizedDescription
            let native = await MediaTyping.nativeAVI(url)
            guard !Task.isCancelled else { return }
            phase = native.map(Phase.native) ?? .failed(message)
        }
    }

    /// What the viewer should know about tracks it is not hearing or seeing.
    private static func note(for movie: ReferenceMovie) -> String? {
        if movie.audioTrackCount == 0, let reason = movie.skippedTracks.first(where: { $0.kind == .audio })?.reason {
            return "No sound: \(reason)"
        }
        if movie.videoTrackCount == 0, let reason = movie.skippedTracks.first(where: { $0.kind == .video })?.reason {
            return "No picture: \(reason)"
        }
        guard !movie.skippedTracks.isEmpty else { return nil }
        return "Some tracks can't play: " + movie.skippedTracks.map(\.reason).joined(separator: "; ")
    }
}

/// Hops progress from the indexing thread to the main actor, dropping
/// updates that arrive while one is still queued.
private final class ProgressRelay: Sendable {
    private let pending = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let apply: @MainActor @Sendable (Double) -> Void

    init(_ apply: @escaping @MainActor @Sendable (Double) -> Void) {
        self.apply = apply
    }

    func send(_ fraction: Double) {
        let wasIdle = pending.withLock { value -> Bool in
            defer { value = fraction }
            return value == nil
        }
        guard wasIdle else { return }
        Task { @MainActor in
            let latest = self.pending.withLock { value -> Double? in
                defer { value = nil }
                return value
            }
            if let latest { self.apply(latest) }
        }
    }
}

// MARK: - Video thumbnail

/// Pull a representative frame out of a video for the grid. Picks 10% in,
/// or 1s in, whichever is later — avoids the black-frame intros some
/// containers have at t=0. Cached size matches our static-image
/// thumbnail max so the grid stays consistent.
enum VideoThumbnail {
    /// AVAssetImageGenerator does not declare Sendable, but Apple documents
    /// `cancelAllCGImageGeneration()` as the cancellation entry point for its
    /// asynchronous requests. This wrapper limits the unchecked crossing to
    /// that single thread-safe operation.
    private final class GeneratorCancellation: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(_ generator: AVAssetImageGenerator) {
            self.generator = generator
        }

        func cancel() {
            generator.cancelAllCGImageGeneration()
        }
    }

    static func generate(url: URL, maxDimension: Int = 256) async -> CGImage? {
        guard !Task.isCancelled else { return nil }

        let asset: AVAsset
        if MediaTyping.needsIndexing(url) {
            // The first couple of seconds are enough for a 1s frame, and
            // keep a long recording from being read end to end for a tile.
            // The asset keeps any scratch file it reads alive itself.
            if let movie = try? await ReferenceMovie.open(url: url, limit: 2) {
                asset = movie.asset
            } else if let native = await MediaTyping.nativeAVI(url) {
                asset = native
            } else {
                return nil
            }
        } else {
            asset = AVURLAsset(url: url)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let cancellation = GeneratorCancellation(generator)

        return await withTaskCancellationHandler {
            // Try 1s, but if duration is shorter use 10% of it. Any load,
            // codec, or cancellation failure simply yields no grid thumbnail.
            let durationSec = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled else { return nil }
            let target = max(0, min(1.0, durationSec * 0.1))
            let time = CMTime(seconds: max(target, durationSec > 1 ? 1 : target), preferredTimescale: 600)
            do {
                let cg = try await generator.image(at: time).image
                return Task.isCancelled ? nil : cg
            } catch {
                return nil
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
