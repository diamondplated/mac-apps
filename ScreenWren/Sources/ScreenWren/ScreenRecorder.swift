import AppKit
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit

/// The region to record, on one display, for a selector result. A window becomes the part
/// of its frame on the display holding its centre.
@MainActor
func recordingRegion(for target: SelectionTarget, screens: [NSScreen] = NSScreen.screens) -> DisplayRegion? {
    switch target {
    case let .region(region): return region
    case .desktop: return nil
    case let .window(candidate):
        let frame = candidate.appKitFrame
        guard let screen = screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            ?? screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        return DisplayRegion(rect: frame.intersection(screen.frame), screen: screen)
    }
}

/// A ScreenCaptureKit stream of one region into a `RecordingWriter`: video only, at the
/// display's scale and 30 frames per second, with the cursor and without ScreenWren's own
/// windows. No audio output is ever added, and both audio sources are switched off.
final class RegionStreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.diamondplated.ScreenWren.recording", qos: .userInitiated)
    private let writer: RecordingWriter
    private var stream: SCStream?
    private var limitReported = false
    private let onLimit: @Sendable () -> Void
    private let onStop: @Sendable (Error) -> Void

    private init(writer: RecordingWriter, onLimit: @escaping @Sendable () -> Void,
                 onStop: @escaping @Sendable (Error) -> Void) {
        self.writer = writer
        self.onLimit = onLimit
        self.onStop = onStop
    }

    static func configuration(for region: DisplayRegion, displayFrame: CGRect) -> SCStreamConfiguration {
        let size = recordingStreamPixelSize(points: region.rect.size, scale: region.scale)
        let global = region.screenCaptureRect
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: global.minX - displayFrame.minX, y: global.minY - displayFrame.minY,
                                          width: global.width, height: global.height)
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingLimits.frameRate))
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 6
        return configuration
    }

    @MainActor
    static func start(region: DisplayRegion, outputURL: URL, onLimit: @escaping @Sendable () -> Void,
                      onStop: @escaping @Sendable (Error) -> Void) async throws -> RegionStreamRecorder {
        guard region.isValid else { throw CaptureSupportError.displayChanged }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureSupportError.missingDisplay
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let own = content.applications.first(where: { $0.processID == processID }) {
            filter = SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter {
                $0.owningApplication?.processID == processID
            })
        }
        let configuration = configuration(for: region, displayFrame: display.frame)
        let writer = try RecordingWriter(url: outputURL, width: configuration.width, height: configuration.height)
        let recorder = RegionStreamRecorder(writer: writer, onLimit: onLimit, onStop: onStop)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        do {
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
        } catch {
            recorder.queue.sync { writer.cancel() }
            throw error
        }
        recorder.stream = stream
        return recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if writer.append(buffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) == .reachedLimit,
           !limitReported {
            limitReported = true
            onLimit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// Stops the stream and finishes the temporary recording, which then lasts until now.
    @MainActor
    func stop() async throws -> RecordingInfo {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let stream {
            self.stream = nil
            nonisolated(unsafe) let unsafeStream = stream
            try? await unsafeStream.stopCapture()
        }
        let writer = writer
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { writer.finish(at: stopTime) { continuation.resume(with: $0) } }
        }
    }
}

/// The recording's life: select, count down, record, stop, review.
@MainActor
final class RecordingCoordinator {
    enum Phase: Equatable { case idle, countdown, starting, recording, finishing }

    private(set) var phase = Phase.idle
    var isActive: Bool { phase != .idle }
    var onStateChange: (() -> Void)?
    var onStatus: ((ScreenWrenStatus) -> Void)?
    var onPermissionRequired: (() -> Void)?
    /// Opens the region and window selector; the handler receives the chosen region.
    var selectRegion: ((@escaping (DisplayRegion) -> Void) -> Void)?

    private var region: DisplayRegion?
    private var outline: RecordingOutlineWindow?
    private var countdown: RecordingCountdownWindow?
    private var countdownTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var recorder: RegionStreamRecorder?
    private var sessionDirectory: URL?
    private var escapeKey: HotKey?
    private var reviews: [RecordingReviewWindow] = []
    private var attempt: UInt64 = 0
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only a change to the recorded display matters; the Dock resizing does not.
                guard let self, let region = self.region, !region.isValid else { return }
                self.displayChanged()
            }
        }
    }

    func toggle() {
        if isActive { stop() } else { begin() }
    }

    func begin() {
        guard phase == .idle else { return }
        selectRegion? { [weak self] region in self?.startCountdown(in: region) }
    }

    private func startCountdown(in region: DisplayRegion) {
        guard phase == .idle else { return }
        attempt &+= 1
        let current = attempt
        self.region = region
        phase = .countdown
        outline = RecordingOutlineWindow(region: region.rect)
        outline?.orderFrontRegardless()
        installEscapeKey()
        countdown = RecordingCountdownWindow(region: region.rect, escapeCancels: escapeKey != nil)
        status(escapeKey == nil ? "Recording in 3 — choose Stop Recording to cancel" : "Recording in 3 — Esc cancels",
               symbol: "record.circle")
        onStateChange?()
        countdownTask = Task { @MainActor [weak self] in
            for value in [3, 2, 1] {
                guard let self, self.attempt == current, self.phase == .countdown else { return }
                self.countdown?.show(value)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.attempt == current, self.phase == .countdown else { return }
            self.countdown?.close()
            self.countdown = nil
            await self.startRecording(attempt: current)
        }
    }

    private func startRecording(attempt current: UInt64) async {
        guard let region else { return }
        phase = .starting
        onStateChange?()
        var directory: URL?
        do {
            let folder = try RecordingFiles.makeSessionDirectory()
            directory = folder
            sessionDirectory = folder
            let recorder = try await RegionStreamRecorder.start(
                region: region, outputURL: folder.appendingPathComponent("Recording.mov"),
                onLimit: { [weak self] in Task { @MainActor in self?.stop(reason: .limit) } },
                onStop: { [weak self] error in Task { @MainActor in self?.stop(reason: .failure(error)) } })
            guard attempt == current, phase == .starting else {
                // Cancelled while the stream was starting.
                _ = try? await recorder.stop()
                try? FileManager.default.removeItem(at: folder)
                return
            }
            self.recorder = recorder
            phase = .recording
            status(escapeKey == nil ? "Recording — choose Stop Recording; stops at 5 minutes"
                                    : "Recording — press Esc or choose Stop Recording; stops at 5 minutes",
                   symbol: "record.circle")
            onStateChange?()
            limitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(RecordingLimits.maximumDuration + 0.5))
                guard !Task.isCancelled, let self, self.attempt == current else { return }
                self.stop(reason: .limit)
            }
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            // A start that was cancelled (or replaced by a newer attempt) must not touch the new one.
            guard attempt == current else { return }
            tearDown()
            sessionDirectory = nil
            if isScreenCapturePermissionError(error) {
                onPermissionRequired?()
            } else {
                status("Couldn’t start recording: \(error.localizedDescription)", symbol: "exclamationmark.triangle",
                       needsAttention: true)
            }
        }
    }

    enum StopReason { case user, limit, failure(Error) }

    func stop() { stop(reason: .user) }

    func stop(reason: StopReason) {
        switch phase {
        case .idle, .finishing:
            return
        case .countdown, .starting:
            attempt &+= 1
            tearDown()
            if let directory = sessionDirectory { try? FileManager.default.removeItem(at: directory) }
            sessionDirectory = nil
            if case let .failure(error) = reason {
                status("Couldn’t start recording: \(error.localizedDescription)", symbol: "exclamationmark.triangle",
                       needsAttention: true)
            } else {
                status("Recording cancelled")
            }
            return
        case .recording:
            break
        }
        guard let recorder else { return }
        phase = .finishing
        region = nil
        let directory = sessionDirectory
        self.recorder = nil
        sessionDirectory = nil
        removeOverlays()
        onStateChange?()
        Task { @MainActor [weak self] in
            do {
                let info = try await recorder.stop()
                guard let self else { return }
                self.phase = .idle
                self.onStateChange?()
                if let directory { self.presentReview(info, directory: directory) }
                switch reason {
                case .limit:
                    self.status("Recording stopped at the 5-minute limit", symbol: "record.circle", needsAttention: true)
                case .failure:
                    self.status("Recording stopped early — the part recorded is ready", symbol: "record.circle",
                                needsAttention: true)
                case .user:
                    self.status("Recording ready — trim, then export", symbol: "record.circle")
                }
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                guard let self else { return }
                self.phase = .idle
                self.onStateChange?()
                if case let .failure(streamError) = reason, isScreenCapturePermissionError(streamError) {
                    self.onPermissionRequired?()
                    return
                }
                self.status("Couldn’t finish the recording: \(error.localizedDescription)",
                            symbol: "exclamationmark.triangle", needsAttention: true)
            }
        }
    }

    private func presentReview(_ info: RecordingInfo, directory: URL) {
        let review = RecordingReviewWindow(recording: info, directory: directory)
        review.onClose = { [weak self, weak review] in
            self?.reviews.removeAll { $0 === review }
        }
        reviews.append(review)
        review.showWindow(nil)
        review.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The display changed under a recording: stop and keep what was recorded.
    func displayChanged() {
        if phase == .recording { stop(reason: .failure(CaptureSupportError.displayChanged)) } else { stop() }
    }

    /// Quitting: nothing recorded survives the process.
    func discardAll() {
        attempt &+= 1
        tearDown()
        recorder = nil
        reviews.forEach { $0.close() }
        reviews.removeAll()
        RecordingFiles.removeProcessDirectory()
    }

    private func tearDown() {
        countdownTask?.cancel()
        countdownTask = nil
        removeOverlays()
        phase = .idle
        region = nil
        onStateChange?()
    }

    private func removeOverlays() {
        limitTask?.cancel()
        limitTask = nil
        escapeKey = nil
        countdown?.close()
        countdown = nil
        outline?.close()
        outline = nil
    }

    /// Esc stops from any app, but only while a countdown or recording is on screen.
    private func installEscapeKey() {
        escapeKey = HotKey(identifier: 100, keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.stop()
        }
    }

    private func status(_ message: String, symbol: String = "viewfinder", needsAttention: Bool = false) {
        onStatus?(ScreenWrenStatus(message: "ScreenWren — \(message)", symbolName: symbol, needsAttention: needsAttention))
    }
}

// MARK: - On-screen marks

/// A borderless, click-through panel that ScreenWren never captures.
@MainActor
private func makeOverlayPanel(frame: CGRect) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    return panel
}

/// A thin red outline drawn just outside the recorded region.
@MainActor
final class RecordingOutlineWindow {
    static let inset: CGFloat = 3
    private let panel: NSPanel

    init(region: CGRect) {
        panel = makeOverlayPanel(frame: region.insetBy(dx: -Self.inset, dy: -Self.inset))
        panel.contentView = RecordingOutlineView()
    }

    func orderFrontRegardless() { panel.orderFrontRegardless() }
    func close() { panel.close() }
}

private final class RecordingOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Outside the recorded pixels, so even an uncooperative capture couldn't include it.
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        inner.lineWidth = 1
        NSColor.systemRed.setStroke()
        inner.stroke()
    }
}

/// 3, 2, 1 in the middle of the selected area.
@MainActor
final class RecordingCountdownWindow {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init(region: CGRect, escapeCancels: Bool = true) {
        let side: CGFloat = 112
        let screen = NSScreen.screens.first { $0.frame.intersects(region) }?.visibleFrame ?? region
        var origin = CGPoint(x: region.midX - side / 2, y: region.midY - side / 2)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - side - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - side - 8)
        panel = makeOverlayPanel(frame: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        panel.level = .screenSaver
        panel.hasShadow = true
        let background = makePanelBackground(material: .hudWindow)
        panel.contentView = background
        label.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        let hint = NSTextField(labelWithString: "Esc Cancels")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        // Only promise Esc when the key was actually free to take.
        hint.isHidden = !escapeCancels
        let stack = NSStackView(views: [label, hint])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.setAccessibilityLabel("Recording countdown")
    }

    func show(_ value: Int) {
        label.stringValue = "\(value)"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(value)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        if panel.isVisible {
            label.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PanelTransition.reducesMotion ? 0.12 : 0.2
                label.animator().alphaValue = 1
            }
        } else {
            PanelTransition.present(panel, slide: 0)
        }
    }

    func close() {
        PanelTransition.dismiss(panel) { [panel] in panel.close() }
    }
}
