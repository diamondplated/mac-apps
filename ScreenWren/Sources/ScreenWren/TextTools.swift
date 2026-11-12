import AppKit
import Vision

struct RecognizedLine: Sendable, Equatable {
    let text: String
    let bounds: CGRect
}
func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return RecognizedLine(text: candidate.string, bounds: observation.boundingBox)
    }
}

enum RedactionKind: String, CaseIterable, Sendable {
    case email, phone, custom
    var title: String {
        switch self {
        case .email: "Email addresses"
        case .phone: "Phone numbers"
        case .custom: "Matching text"
        }
    }
}
struct RedactionSuggestion: Sendable, Equatable {
    let kind: RedactionKind
    let text: String
    let bounds: CGRect  // Vision normalized bottom-left coordinates.
}
func redactionSuggestions(in lines: [RecognizedLine], emails: Bool, phones: Bool, matching text: String)
    -> [RedactionSuggestion]
{
    let emailPattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    let emailRegex = try? NSRegularExpression(pattern: emailPattern, options: .caseInsensitive)
    let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    var output: [RedactionSuggestion] = []
    for line in lines {
        let full = NSRange(line.text.startIndex..., in: line.text)
        var matches: [(RedactionKind, NSRange)] = []
        if emails { matches += (emailRegex?.matches(in: line.text, range: full) ?? []).map { (.email, $0.range) } }
        if phones { matches += (phoneDetector?.matches(in: line.text, range: full) ?? []).map { (.phone, $0.range) } }
        if !text.isEmpty,
            let regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: text), options: .caseInsensitive)
        {
            matches += regex.matches(in: line.text, range: full).map { (.custom, $0.range) }
        }
        for (kind, range) in matches {
            guard let swiftRange = Range(range, in: line.text) else { continue }
            // Mask the whole recognized line conservatively; no partial-character leaks.
            let value = String(line.text[swiftRange])
            if !output.contains(where: { $0.bounds == line.bounds }) {
                output.append(RedactionSuggestion(kind: kind, text: value, bounds: line.bounds))
            }
        }
    }
    return output
}
func redactionPixelRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
    CGRect(
        x: normalized.minX * CGFloat(width), y: (1 - normalized.maxY) * CGFloat(height),
        width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height)
    )
    .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
}
func applyRedactions(_ image: CGImage, bounds: [CGRect]) throws -> CGImage {
    try renderCGImage(width: image.width, height: image.height) { context in
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in bounds {
            let rect = redactionPixelRect(box, width: image.width, height: image.height)
            context.fill(
                CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height))
        }
    }
}

@MainActor
private final class RedactionPreview: NSView {
    let image: CGImage
    var onManualMask: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var imageFrame: CGRect {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        dragRect = normalizedRect(from: dragStart, to: convert(event.locationInWindow, from: nil)).intersection(
            imageFrame)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragRect = nil
            needsDisplay = true
        }
        guard let rect = dragRect, rect.width >= 2, rect.height >= 2, imageFrame.width > 0, imageFrame.height > 0 else {
            return
        }
        onManualMask?(
            CGRect(
                x: (rect.minX - imageFrame.minX) / imageFrame.width,
                y: (rect.minY - imageFrame.minY) / imageFrame.height, width: rect.width / imageFrame.width,
                height: rect.height / imageFrame.height))
    }
    var masks: [CGRect] = [] { didSet { needsDisplay = true } }
    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Redaction preview. Selected suggestions appear as opaque black masks.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSImage(cgImage: image, size: size).draw(in: rect)
        if let dragRect {
            NSColor.systemOrange.withAlphaComponent(0.6).setFill()
            dragRect.fill()
        }
        NSColor.black.setFill()
        for mask in masks {
            let pixels = redactionPixelRect(mask, width: image.width, height: image.height)
            CGRect(
                x: rect.minX + pixels.minX * scale, y: rect.minY + (CGFloat(image.height) - pixels.maxY) * scale,
                width: pixels.width * scale, height: pixels.height * scale
            ).fill()
        }
    }
}

@MainActor
final class RedactionReviewWindow: NSWindowController, NSWindowDelegate {
    private let image: CGImage
    private let preview: RedactionPreview
    private let emails = NSButton(checkboxWithTitle: "Emails", target: nil, action: nil)
    private let phones = NSButton(checkboxWithTitle: "Phones", target: nil, action: nil)
    private let match = NSTextField(string: "")
    private let rows = TopAlignedStackView()
    private let status = NSTextField(labelWithString: "Recognizing text locally…")
    private let apply = NSButton(title: "", target: nil, action: nil)
    private var lines: [RecognizedLine] = []
    private var suggestions: [RedactionSuggestion] = []
    private var manualMasks: [CGRect] = []
    private var checks: [NSButton] = []
    private var task: Task<Void, Never>?
    private let onApply: (CGImage, ClipboardTicket?) -> Void
    private let copiesOnApproval: Bool
    var onClose: (() -> Void)?
    init(
        image: CGImage, actionTitle: String, copiesOnApproval: Bool = true,
        recognize: @escaping @Sendable (CGImage) throws -> [RecognizedLine] = recognizeLines(in:),
        onApply: @escaping (CGImage, ClipboardTicket?) -> Void
    ) {
        self.image = image
        preview = RedactionPreview(image: image)
        self.onApply = onApply
        self.copiesOnApproval = copiesOnApproval
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 700), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Review Redactions"
        window.minSize = CGSize(width: 660, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        preview.onManualMask = { [weak self] rect in
            self?.manualMasks.append(rect)
            self?.updateMasks()
        }
        emails.state = .on
        phones.state = .on
        for button in [emails, phones] {
            button.target = self
            button.action = #selector(findSuggestions)
        }
        match.placeholderString = "Also mask this text"
        match.setAccessibilityLabel("Literal text to redact")
        match.widthAnchor.constraint(equalToConstant: 210).isActive = true
        match.target = self
        match.action = #selector(findSuggestions)
        let controls = NSStackView(views: [
            emails, phones, match, NSButton(title: "Find", target: self, action: #selector(findSuggestions)),
            NSButton(title: "Clear Drawn Masks", target: self, action: #selector(clearManualMasks)),
        ])
        controls.spacing = 12
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        let scroll = NSScrollView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        apply.title = actionTitle
        apply.target = self
        apply.action = #selector(applySelected)
        apply.isEnabled = false
        apply.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        status.font = .preferredFont(forTextStyle: .callout)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, cancelButton, apply])
        footer.distribution = .fill
        footer.spacing = 8
        window.subtitle = copiesOnApproval
            ? "Stays off the clipboard until approved"
            : "Applies to the editor; can’t retract an earlier copy"
        let explanation = NSTextField(labelWithString: "Check every mask; suggestions can miss text. Drag to add one.")
        explanation.font = .preferredFont(forTextStyle: .callout)
        explanation.textColor = .secondaryLabelColor
        let content = NSStackView(views: [explanation, preview, controls, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 140),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        window.center()
        let payload = SendableImage(image: image)
        task = Task { @MainActor [weak self] in
            do {
                let lines = try await Task.detached(priority: .userInitiated) { try recognize(payload.image) }
                    .value
                try Task.checkCancellation()
                guard let self else { return }
                self.lines = lines
                self.findSuggestions()
                self.apply.isEnabled = true
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Recognition failed. Draw masks on the preview before approving."
                self?.apply.isEnabled = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func findSuggestions() {
        suggestions = redactionSuggestions(
            in: lines, emails: emails.state == .on, phones: phones.state == .on, matching: match.stringValue)
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        checks = []
        for suggestion in suggestions {
            let check = NSButton(
                checkboxWithTitle: "\(suggestion.kind.title): \(suggestion.text)", target: self,
                action: #selector(updateMasks))
            check.state = .on
            check.lineBreakMode = .byTruncatingTail
            checks.append(check)
            rows.addArrangedSubview(check)
        }
        updateMasks()
    }
    @objc private func clearManualMasks() {
        manualMasks = []
        updateMasks()
    }
    @objc private func updateMasks() {
        preview.masks =
            suggestions.indices.filter { checks[$0].state == .on }.map { suggestions[$0].bounds } + manualMasks
        status.stringValue =
            suggestions.isEmpty
            ? "No matches found. This does not mean the image contains no private information."
            : "\(preview.masks.count) masks selected (\(manualMasks.count) drawn)."
    }
    @objc private func applySelected() {
        guard apply.isEnabled else { return }
        apply.isEnabled = false
        let payload = SendableImage(image: image)
        let masks = preview.masks
        let ticket = copiesOnApproval ? ClipboardTicket() : nil
        task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    SendableImage(image: try applyRedactions(payload.image, bounds: masks))
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.onApply(result.image, ticket)
                self.close()
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Couldn’t apply redactions."
                self?.apply.isEnabled = true
            }
        }
    }
    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        super.close()
    }
    @objc private func cancel() { close() }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        lines = []
        suggestions = []
        onClose?()
    }
}
