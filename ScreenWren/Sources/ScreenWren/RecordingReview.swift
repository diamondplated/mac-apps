import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Formats seconds as 0:04.2.
func recordingTimeLabel(_ seconds: Double) -> String {
    let tenths = Int((max(0, seconds) * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

/// Two handles over a track: the start and end of the part to keep.
final class RecordingTrimView: NSView {
    var duration: Double { didSet { trim = RecordingTrim.clamped(start: trim.start, end: trim.end, duration: duration) } }
    private(set) var trim: RecordingTrim
    var onChange: ((RecordingTrim) -> Void)?
    private enum Handle { case start, end }
    private var dragging: Handle?
    private var focusedHandle = Handle.start
    private lazy var startElement = HandleElement(owner: self, isStart: true)
    private lazy var endElement = HandleElement(owner: self, isStart: false)
    private static let handleWidth: CGFloat = 10

    init(duration: Double) {
        self.duration = duration
        trim = RecordingTrim(start: 0, end: duration)
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 30))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Trim")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: CornerRadius.control, yRadius: CornerRadius.control).fill()
    }

    func setTrim(_ value: RecordingTrim, notify: Bool = true) {
        trim = RecordingTrim.clamped(start: value.start, end: value.end, duration: duration)
        needsDisplay = true
        startElement.update()
        endElement.update()
        if notify { onChange?(trim) }
    }

    private var track: CGRect { bounds.insetBy(dx: Self.handleWidth / 2 + 1, dy: 4) }

    private func x(for time: Double) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + CGFloat(time / duration) * track.width
    }

    private func time(for x: CGFloat) -> Double {
        guard track.width > 0 else { return 0 }
        return Double((x - track.minX) / track.width) * duration
    }

    fileprivate func handleFrame(isStart: Bool) -> CGRect {
        let center = x(for: isStart ? trim.start : trim.end)
        return CGRect(x: center - Self.handleWidth / 2, y: bounds.minY + 1, width: Self.handleWidth,
                      height: bounds.height - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackPath = NSBezierPath(roundedRect: track, xRadius: CornerRadius.control, yRadius: CornerRadius.control)
        NSColor.quaternarySystemFill.setFill()
        trackPath.fill()
        let kept = CGRect(x: x(for: trim.start), y: track.minY, width: x(for: trim.end) - x(for: trim.start),
                          height: track.height)
        let keptPath = NSBezierPath(rect: kept)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        keptPath.fill()
        NSColor.controlAccentColor.setStroke()
        let edges = NSBezierPath()
        edges.move(to: CGPoint(x: kept.minX, y: kept.maxY - 0.5))
        edges.line(to: CGPoint(x: kept.maxX, y: kept.maxY - 0.5))
        edges.move(to: CGPoint(x: kept.minX, y: kept.minY + 0.5))
        edges.line(to: CGPoint(x: kept.maxX, y: kept.minY + 0.5))
        edges.lineWidth = 1
        edges.stroke()
        for isStart in [true, false] {
            let handle = NSBezierPath(roundedRect: handleFrame(isStart: isStart), xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.setFill()
            handle.fill()
            let grip = handleFrame(isStart: isStart).insetBy(dx: 4, dy: 9)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let toStart = abs(point.x - x(for: trim.start))
        let toEnd = abs(point.x - x(for: trim.end))
        dragging = toStart <= toEnd ? .start : .end
        focusedHandle = dragging ?? .start
        move(dragging!, to: time(for: point.x))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        move(dragging, to: time(for: convert(event.locationInWindow, from: nil).x))
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        switch Int(event.keyCode) {
        case kVK_LeftArrowKey: nudge(by: -step)
        case kVK_RightArrowKey: nudge(by: step)
        case kVK_TabKey where !event.modifierFlags.contains(.shift) && focusedHandle == .start:
            focusedHandle = .end
        case kVK_TabKey where event.modifierFlags.contains(.shift) && focusedHandle == .end:
            focusedHandle = .start
        default: super.keyDown(with: event)
        }
    }

    fileprivate func nudge(isStart: Bool, by step: Double) {
        focusedHandle = isStart ? .start : .end
        nudge(by: step)
    }

    private func nudge(by step: Double) {
        move(focusedHandle, to: (focusedHandle == .start ? trim.start : trim.end) + step)
    }

    private func move(_ handle: Handle, to time: Double) {
        let minimum = min(RecordingLimits.minimumTrimLength, duration)
        let value: RecordingTrim = switch handle {
        case .start: RecordingTrim(start: min(max(0, time), trim.end - minimum), end: trim.end)
        case .end: RecordingTrim(start: trim.start, end: max(min(duration, time), trim.start + minimum))
        }
        guard value != trim else { return }
        setTrim(value)
    }

    override func accessibilityChildren() -> [Any]? { [startElement, endElement] }

    /// Each handle is an adjustable slider for VoiceOver. AppKit calls it on the main thread.
    fileprivate final class HandleElement: NSAccessibilityElement {
        nonisolated(unsafe) private weak var owner: RecordingTrimView?
        private let isStart: Bool

        @MainActor
        init(owner: RecordingTrimView, isStart: Bool) {
            self.owner = owner
            self.isStart = isStart
            super.init()
            setAccessibilityRole(.slider)
            setAccessibilityLabel(isStart ? "Trim start" : "Trim end")
            setAccessibilityParent(owner)
            update()
        }

        @MainActor
        func update() {
            guard let owner else { return }
            setAccessibilityValue(recordingTimeLabel(isStart ? owner.trim.start : owner.trim.end))
            setAccessibilityFrameInParentSpace(owner.handleFrame(isStart: isStart))
        }

        override func accessibilityPerformIncrement() -> Bool { step(0.1) }
        override func accessibilityPerformDecrement() -> Bool { step(-0.1) }

        private func step(_ amount: Double) -> Bool {
            let owner = owner
            let isStart = isStart
            MainActor.assumeIsolated { owner?.nudge(isStart: isStart, by: amount) }
            return true
        }
    }
}

private let kVK_LeftArrowKey = 0x7B
private let kVK_RightArrowKey = 0x7C
private let kVK_TabKey = 0x30

/// File drags of an exported recording: the receiver gets its own copy.
final class FileCopyPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let source: URL
    private let filename: String
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ScreenWren recording file promise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(source: URL, filename: String) {
        self.source = source
        self.filename = filename
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// Review after a recording: the clip loops, the trim control picks the part to keep, and
/// the options show the exported size as they change. Export, Copy and drag-out use the
/// same encoded file. Closing the window deletes everything it wrote.
@MainActor
final class RecordingReviewWindow: NSWindowController, NSWindowDelegate {
    private let recording: RecordingInfo
    private let directory: URL
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerView = AVPlayerView()
    private let poster = NSImageView()
    private let trimView: RecordingTrimView
    private let trimLabel = NSTextField(labelWithString: "")
    private let format = NSPopUpButton()
    private let size = NSPopUpButton()
    private let widthField = NSTextField()
    private let frameRate = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var dragView: PNGPromiseDragView!
    private var encodeTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var revision = 0
    private var encoded: (url: URL, options: RecordingExportOptions, trim: RecordingTrim)?
    private var options: RecordingExportOptions
    private var isClosed = false
    private var readyObservation: NSKeyValueObservation?
    var onClose: (() -> Void)?

    init(recording: RecordingInfo, directory: URL, defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general) {
        self.recording = recording
        self.directory = directory
        self.defaults = defaults
        self.pasteboard = pasteboard
        options = RecordingExportOptions.load(from: defaults)
        trimView = RecordingTrimView(duration: recording.duration)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Recording"
        window.subtitle = "\(recording.width) × \(recording.height) · \(recordingTimeLabel(recording.duration))"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        loadPoster()
        restartLoop()
        scheduleEncode(after: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(in window: NSWindow) {
        // The clip's own shape, within limits, so it isn't lost in letterboxing.
        let previewHeight = min(340, max(180, 560 * CGFloat(recording.height) / CGFloat(max(1, recording.width))))
        let preview = SemanticLayerView(fill: .black, border: .separatorColor, borderWidth: 1,
                                        cornerRadius: CornerRadius.card)
        preview.layer?.masksToBounds = true
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.image)
        preview.setAccessibilityLabel("Recording preview")
        poster.imageScaling = .scaleProportionallyUpOrDown
        // The poster's image size must not widen the window.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            poster.setContentCompressionResistancePriority(.fittingSizeCompression, for: orientation)
            poster.setContentHuggingPriority(.fittingSizeCompression, for: orientation)
        }
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.allowsPictureInPicturePlayback = false
        player.isMuted = true
        // The first frame shows until the video is ready to draw, so the window never opens black.
        for view in [playerView, poster] {
            view.translatesAutoresizingMaskIntoConstraints = false
            preview.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                view.topAnchor.constraint(equalTo: preview.topAnchor),
                view.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            ])
        }

        readyObservation = playerView.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, change in
            let ready = change.newValue ?? false
            MainActor.assumeIsolated { self?.poster.isHidden = ready }
        }
        trimView.onChange = { [weak self] _ in self?.trimChanged() }
        trimLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                    weight: .regular)
        trimLabel.textColor = .secondaryLabelColor
        updateTrimLabel()

        format.addItems(withTitles: RecordingFormat.allCases.map(\.title))
        format.target = self
        format.action = #selector(optionsChanged)
        format.setAccessibilityLabel("Format")
        size.target = self
        size.action = #selector(optionsChanged)
        size.setAccessibilityLabel("Size")
        widthField.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: RecordingExportOptions.minimumWidth)
            formatter.maximum = NSNumber(value: recording.width)
            return formatter
        }()
        widthField.placeholderString = "Width"
        widthField.alignment = .right
        widthField.target = self
        widthField.action = #selector(optionsChanged)
        widthField.setAccessibilityLabel("Width in pixels")
        widthField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let pixels = NSTextField(labelWithString: "px")
        pixels.textColor = .secondaryLabelColor
        let widthRow = NSStackView(views: [widthField, pixels])
        widthRow.spacing = 4
        frameRate.addItems(withTitles: RecordingExportOptions.gifFrameRates.map { "\($0) fps" })
        frameRate.target = self
        frameRate.action = #selector(optionsChanged)
        frameRate.setAccessibilityLabel("GIF frame rate")
        let optionsRow = NSStackView(views: [format, size, widthRow, frameRate])
        optionsRow.spacing = 10
        applyOptionsToControls()

        status.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                 weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let dragIcon = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "Drag recording out")
            ?? NSImage()
        dragView = PNGPromiseDragView(image: dragIcon) { [weak self] in
            self?.makeDragProvider() ?? NSFilePromiseProvider()
        }
        dragView.contentTintColor = .secondaryLabelColor
        dragView.toolTip = "Drag the exported recording out"
        dragView.setAccessibilityLabel("Drag recording out")
        dragView.setAccessibilityHelp("Drag to save the exported recording where you drop it.")
        dragView.translatesAutoresizingMaskIntoConstraints = false
        dragView.isHidden = true
        let discard = NSButton(title: "Discard", target: window, action: #selector(NSWindow.performClose(_:)))
        discard.keyEquivalent = "\u{1b}"
        discard.toolTip = "Close and delete this recording"
        copyButton.target = self
        copyButton.action = #selector(copyRecording)
        copyButton.toolTip = "Copy the exported file"
        exportButton.target = self
        exportButton.action = #selector(exportRecordingFile)
        exportButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [status, progress, dragView, discard, copyButton, exportButton])
        footer.distribution = .fill
        footer.spacing = 8
        footer.setCustomSpacing(12, after: dragView)

        let content = NSStackView(views: [preview, trimView, trimLabel, optionsRow, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(4, after: trimView)
        content.setCustomSpacing(16, after: trimLabel)
        content.setCustomSpacing(20, after: optionsRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: previewHeight),
            trimView.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            dragView.widthAnchor.constraint(equalToConstant: 24),
            dragView.heightAnchor.constraint(equalToConstant: 24),
        ])
        root.layoutSubtreeIfNeeded()
        window.setContentSize(CGSize(width: 600, height: content.fittingSize.height + 40))
        window.center()
    }

    // MARK: Options

    private var sizeChoices: [RecordingOutputSize] {
        [.original, .half, .width(customWidth)]
    }

    private var customWidth: Int {
        if case let .width(width) = options.size { return width }
        return min(recording.width, 800)
    }

    private func applyOptionsToControls() {
        format.selectItem(at: RecordingFormat.allCases.firstIndex(of: options.format) ?? 0)
        size.removeAllItems()
        for choice in [RecordingOutputSize.original, .half] {
            let pixels = recordingOutputPixelSize(sourceWidth: recording.width, sourceHeight: recording.height,
                                                  size: choice, format: options.format)
            size.addItem(withTitle: "\(choice == .original ? "Original" : "Half") (\(pixels.width) × \(pixels.height))")
        }
        size.addItem(withTitle: "Custom Width")
        switch options.size {
        case .original: size.selectItem(at: 0)
        case .half: size.selectItem(at: 1)
        case .width: size.selectItem(at: 2)
        }
        widthField.integerValue = customWidth
        widthField.superview?.isHidden = { if case .width = options.size { return false } else { return true } }()
        frameRate.selectItem(at: RecordingExportOptions.gifFrameRates.firstIndex(of: options.gifFrameRate) ?? 1)
        frameRate.isHidden = options.format != .gif
    }

    @objc private func optionsChanged() {
        var next = options
        next.format = RecordingFormat.allCases[max(0, format.indexOfSelectedItem)]
        switch size.indexOfSelectedItem {
        case 0: next.size = .original
        case 1: next.size = .half
        default:
            let typed = widthField.integerValue > 0 ? widthField.integerValue : customWidth
            next.size = .width(min(recording.width, max(RecordingExportOptions.minimumWidth, typed)))
        }
        next.gifFrameRate = RecordingExportOptions.gifFrameRates[max(0, frameRate.indexOfSelectedItem)]
        guard next != options else { return }
        options = next
        options.save(to: defaults)
        applyOptionsToControls()
        scheduleEncode(after: 0.15)
    }

    private func trimChanged() {
        updateTrimLabel()
        restartLoop(after: 0.25)
        scheduleEncode(after: 0.4)
    }

    private func updateTrimLabel() {
        let trim = trimView.trim
        trimLabel.stringValue = "\(recordingTimeLabel(trim.start)) – \(recordingTimeLabel(trim.end)) · "
            + "\(String(format: "%.1f", trim.length)) s"
    }

    // MARK: Playback

    private func loadPoster() {
        let url = recording.url
        Task { @MainActor [weak self] in
            let first = await Task.detached(priority: .userInitiated) { () -> SendableImage? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                return (try? await generator.image(at: .zero).image).map(SendableImage.init)
            }.value
            guard let image = first?.image, let self else { return }
            self.poster.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
    }

    private func restartLoop(after delay: Double = 0) {
        loopTask?.cancel()
        let range = trimView.trim.timeRange
        loopTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            self.looper?.disableLooping()
            self.player.removeAllItems()
            let item = AVPlayerItem(asset: AVURLAsset(url: self.recording.url))
            self.looper = AVPlayerLooper(player: self.player, templateItem: item, timeRange: range)
            self.player.play()
        }
    }

    // MARK: Encoding

    private func scheduleEncode(after delay: Double) {
        encodeTask?.cancel()
        revision += 1
        let expected = revision
        let options = options
        let trim = trimView.trim
        let recording = recording
        let output = directory.appendingPathComponent("Export-\(expected).\(options.format.fileExtension)")
        encoded = nil
        exportButton.isEnabled = false
        copyButton.isEnabled = false
        dragView.isHidden = true
        progress.isHidden = false
        let pixels = recordingOutputPixelSize(sourceWidth: recording.width, sourceHeight: recording.height,
                                              size: options.size, format: options.format)
        status.stringValue = "\(pixels.width) × \(pixels.height) · \(String(format: "%.1f", trim.length)) s · Encoding…"
        progress.startAnimation(nil)
        encodeTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await exportRecording(recording, trim: trim, options: options, to: output)
                }.value
                try Task.checkCancellation()
                guard let self, self.revision == expected, !self.isClosed else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                self.removeOtherExports(keeping: output)
                self.encoded = (output, options, trim)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                self.status.stringValue = "\(pixels.width) × \(pixels.height) · \(String(format: "%.1f", trim.length)) s · "
                    + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                self.exportButton.isEnabled = true
                self.copyButton.isEnabled = true
                self.dragView.isHidden = false
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                guard let self, self.revision == expected else { return }
                self.status.stringValue = "Couldn’t encode: \(error.localizedDescription)"
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
            }
        }
    }

    private func removeOtherExports(keeping kept: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // By name: the listing may spell the temporary folder through /private.
        for file in files where file.lastPathComponent.hasPrefix("Export-") && file.lastPathComponent != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func filename() -> String {
        recordingFilename(format: encoded?.options.format ?? options.format)
    }

    private var contentType: UTType { (encoded?.options.format ?? options.format) == .gif ? .gif : .mpeg4Movie }

    @objc private func exportRecordingFile() {
        guard let window, let encoded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = filename()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: Self.copyForReplacing(encoded.url))
                    } else {
                        try FileManager.default.copyItem(at: encoded.url, to: destination)
                    }
                    self?.status.stringValue = "Saved \(destination.lastPathComponent)"
                } catch {
                    self?.status.stringValue = "Couldn’t save: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func copyForReplacing(_ url: URL) throws -> URL {
        let copy = url.deletingLastPathComponent().appendingPathComponent("Replacing-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// The clipboard gets its own copy of the file, kept until ScreenWren quits, because the
    /// review folder goes when this window closes. A GIF also goes on as image data.
    @objc private func copyRecording() {
        guard let encoded else { return }
        do {
            let folder = try RecordingFiles.clipboardDirectory()
            for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: old)
            }
            let copy = folder.appendingPathComponent(filename())
            try FileManager.default.copyItem(at: encoded.url, to: copy)
            _ = ClipboardDeliveryOrder.shared.begin()
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(copy.absoluteString, forType: .fileURL)
            if encoded.options.format == .gif, let data = try? Data(contentsOf: copy) {
                item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
            }
            guard pasteboard.writeObjects([item]) else { throw CaptureError.clipboardWriteFailed }
            status.stringValue = "Copied \(encoded.options.format == .gif ? "GIF" : "MP4")"
        } catch {
            status.stringValue = "Couldn’t copy: \(error.localizedDescription)"
        }
    }

    private func makeDragProvider() -> NSFilePromiseProvider? {
        guard let encoded else { return nil }
        let delegate = FileCopyPromiseDelegate(source: encoded.url, filename: filename())
        let provider = NSFilePromiseProvider(fileType: contentType.identifier, delegate: delegate)
        provider.userInfo = delegate // The delegate is weak.
        return provider
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        readyObservation = nil
        encodeTask?.cancel()
        loopTask?.cancel()
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
        playerView.player = nil
        try? FileManager.default.removeItem(at: directory)
        onClose?()
        onClose = nil
    }

    override func close() {
        super.close()
        if !isClosed { windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
    }
}
