import AppKit

func shortcutAwareStatus(_ status: ScreenWrenStatus, hasUnavailableShortcuts: Bool) -> ScreenWrenStatus {
    guard hasUnavailableShortcuts else { return status }
    return ScreenWrenStatus(message: status.message + "\nA shortcut is unavailable",
                           symbolName: "exclamationmark.triangle")
}

enum CaptureStatusRecoveryAction: Equatable {
    case capture
    case text
    case recents
    case editors

    var title: String {
        switch self {
        case .capture: "Capture Again"
        case .text: "Select Text Again"
        case .recents: "Browse Recents"
        case .editors: "Show Editors"
        }
    }
}

@MainActor
func captureStatusMenuItem(for status: ScreenWrenStatus) -> NSMenuItem {
    let item = NSMenuItem(title: status.message, action: nil, keyEquivalent: "")
    item.isEnabled = false
    let label = NSTextField(wrappingLabelWithString: status.message)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = 280
    let height = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 280, height: 1000)).height ?? 16
    label.frame = CGRect(x: 14, y: 8, width: 280, height: height)
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 308, height: label.frame.height + 16))
    view.addSubview(label)
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    view.setAccessibilityLabel(status.message)
    item.view = view
    return item
}

@MainActor
private final class CaptureStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureStatusButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds only product status text; no captured pixels, recognized text, or window metadata.
@MainActor
final class CaptureStatusPresenter {
    private(set) var notice: CaptureStatusWindow?
    private let onRecovery: (CaptureStatusRecoveryAction) -> Void

    init(onRecovery: @escaping (CaptureStatusRecoveryAction) -> Void) {
        self.onRecovery = onRecovery
    }

    func update(_ status: ScreenWrenStatus) {
        notice?.close()
        notice = nil
        guard status.needsAttention || status.swatch != nil else { return }
        let notice = CaptureStatusWindow(status: status, onRecovery: onRecovery)
        notice.onClose = { [weak self] in self?.notice = nil }
        self.notice = notice
        // A colour confirmation needs no action, so it goes sooner.
        notice.present(duration: status.swatch == nil ? .seconds(8) : .seconds(3))
    }
}

@MainActor
final class CaptureStatusWindow: NSWindowController {
    private var expiry: Task<Void, Never>?
    private let recoveryAction: CaptureStatusRecoveryAction?
    private let onRecovery: (CaptureStatusRecoveryAction) -> Void
    private var isClosing = false
    var onClose: (() -> Void)?

    init(status: ScreenWrenStatus, onRecovery: @escaping (CaptureStatusRecoveryAction) -> Void) {
        recoveryAction = status.recoveryAction
        self.onRecovery = onRecovery
        let panel = CaptureStatusPanel(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ScreenWren Capture Status"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let background = makePanelBackground()
        panel.contentView = background
        super.init(window: panel)

        let icon: NSView
        if let swatch = status.swatch {
            let well = SemanticLayerView(fill: swatch, border: .separatorColor, borderWidth: 1,
                                         cornerRadius: CornerRadius.control)
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 24), well.heightAnchor.constraint(equalToConstant: 24),
            ])
            icon = well
        } else {
            let symbol = NSImageView(
                image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
            symbol.contentTintColor = .systemOrange
            icon = symbol
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        // A colour confirmation reads as just the value: "#3A7BD5 copied".
        let text = status.swatch == nil ? status.message
            : status.message.replacingOccurrences(of: "ScreenWren — ", with: "")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .body)
        label.preferredMaxLayoutWidth = 268
        let message = NSStackView(views: [icon, label])
        message.alignment = status.swatch == nil ? .top : .centerY
        message.spacing = 10
        let dismiss = CaptureStatusButton(title: "Dismiss", target: self, action: #selector(dismiss))
        dismiss.setAccessibilityLabel("Dismiss capture status")
        var buttons: [NSView] = status.swatch == nil || status.recoveryAction != nil ? [dismiss] : []
        if let recoveryAction {
            let recover = CaptureStatusButton(title: recoveryAction.title, target: self, action: #selector(recover))
            recover.bezelColor = .controlAccentColor
            buttons.append(recover)
        }
        let actions = NSStackView(views: buttons)
        actions.spacing = 8
        let content = NSStackView(views: buttons.isEmpty ? [message] : [message, actions])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            message.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        background.layoutSubtreeIfNeeded()
        let minimumHeight: CGFloat = buttons.isEmpty ? 56 : 88
        let width: CGFloat = buttons.isEmpty ? min(340, content.fittingSize.width + 32) : 340
        panel.setContentSize(CGSize(width: width, height: max(minimumHeight, content.fittingSize.height + 32)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(duration: Duration = .seconds(8)) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame, let window {
            window.setFrameOrigin(CGPoint(x: visible.maxX - window.frame.width - 16,
                                          y: visible.maxY - window.frame.height - 16))
        }
        if let window { PanelTransition.present(window, slide: -8) }
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
                try Task.checkCancellation()
                self?.close()
            } catch {}
        }
    }

    /// Callers see the notice as gone at once; the panel itself fades out.
    override func close() {
        expiry?.cancel()
        expiry = nil
        guard !isClosing else { return }
        isClosing = true
        let completion = onClose
        onClose = nil
        completion?()
        guard let window else { return }
        PanelTransition.dismiss(window) { super.close() }
    }

    @objc private func dismiss() { close() }

    @objc private func recover() {
        guard let recoveryAction else { return }
        close()
        onRecovery(recoveryAction)
    }
}
