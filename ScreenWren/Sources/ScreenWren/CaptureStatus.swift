import AppKit

func shortcutAwareStatus(_ status: ScreenWrenStatus, hasUnavailableShortcuts: Bool) -> ScreenWrenStatus {
    guard hasUnavailableShortcuts else { return status }
    return ScreenWrenStatus(message: status.message + "\nA shortcut is unavailable — open Readiness to fix it.",
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
        guard status.needsAttention else { return }
        let notice = CaptureStatusWindow(status: status, onRecovery: onRecovery)
        notice.onClose = { [weak self] in self?.notice = nil }
        self.notice = notice
        notice.present()
    }
}

@MainActor
final class CaptureStatusWindow: NSWindowController {
    private var expiry: Task<Void, Never>?
    private let recoveryAction: CaptureStatusRecoveryAction?
    private let onRecovery: (CaptureStatusRecoveryAction) -> Void
    var onClose: (() -> Void)?

    init(status: ScreenWrenStatus, onRecovery: @escaping (CaptureStatusRecoveryAction) -> Void) {
        recoveryAction = status.recoveryAction
        self.onRecovery = onRecovery
        let panel = CaptureStatusPanel(
            contentRect: CGRect(x: 0, y: 0, width: 350, height: 130),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ScreenWren Capture Status"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        super.init(window: panel)

        let label = NSTextField(wrappingLabelWithString: status.message)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 318
        let dismiss = CaptureStatusButton(title: "Dismiss", target: self, action: #selector(dismiss))
        dismiss.setAccessibilityLabel("Dismiss capture status")
        var buttons: [NSView] = [dismiss]
        if let recoveryAction {
            buttons.append(CaptureStatusButton(title: recoveryAction.title, target: self, action: #selector(recover)))
        }
        let actions = NSStackView(views: buttons)
        actions.spacing = 8
        let content = NSStackView(views: [label, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
            label.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(CGSize(width: 350, height: max(100, content.fittingSize.height + 32)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(duration: Duration = .seconds(8)) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame, let window {
            window.setFrameOrigin(CGPoint(x: visible.maxX - window.frame.width - 16,
                                          y: visible.maxY - window.frame.height - 16))
        }
        window?.orderFrontRegardless()
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
                try Task.checkCancellation()
                self?.close()
            } catch {}
        }
    }

    override func close() {
        expiry?.cancel()
        expiry = nil
        super.close()
        let completion = onClose
        onClose = nil
        completion?()
    }

    @objc private func dismiss() { close() }

    @objc private func recover() {
        guard let recoveryAction else { return }
        close()
        onRecovery(recoveryAction)
    }
}
