import AppKit

@MainActor
final class TopAlignedStackView: NSStackView { override var isFlipped: Bool { true } }

struct SessionCapture {
    let id: UUID
    let image: CGImage
    let date: Date
    let scale: CGFloat
    init(image: CGImage, date: Date = Date(), scale: CGFloat = 1, id: UUID = UUID()) {
        self.image = image
        self.date = date
        self.scale = scale
        self.id = id
    }
    var byteCount: Int { image.bytesPerRow * image.height }
}

@MainActor
struct ClipboardTicket {
    let generation: UInt64
    let changeCount: Int
    init(on pasteboard: NSPasteboard = .general) {
        generation = ClipboardDeliveryOrder.shared.begin()
        changeCount = pasteboard.changeCount
    }
    func isCurrent(on pasteboard: NSPasteboard = .general) -> Bool {
        ClipboardDeliveryOrder.shared.isCurrent(generation)
            && clipboardStateIsUnchanged(since: changeCount, on: pasteboard)
    }
}

enum RecentAction { case copy, edit, pin, save }

@MainActor
final class RecentPickerWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var records: [SessionCapture] = []
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var singleSelectionButtons: [NSButton] = []
    private var removeButton: NSButton?
    private let onAction: (RecentAction, UUID) -> Void
    private let onDelete: ([UUID]) -> Void
    var onClose: (() -> Void)?
    init(onAction: @escaping (RecentAction, UUID) -> Void, onDelete: @escaping ([UUID]) -> Void) {
        self.onAction = onAction
        self.onDelete = onDelete
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Recent Captures"
        window.subtitle = "This session"
        window.minSize = CGSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let preview = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        preview.title = "Capture"
        preview.width = 180
        let details = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details"))
        details.title = "Details"
        details.width = 340
        table.addTableColumn(preview)
        table.addTableColumn(details)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 86
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(edit)
        table.setAccessibilityLabel("Recent captures")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copy.keyEquivalent = "\r"
        let edit = NSButton(title: "Edit", target: self, action: #selector(edit))
        let pin = NSButton(title: "Pin", target: self, action: #selector(pin))
        let save = NSButton(title: "Export…", target: self, action: #selector(save))
        let remove = NSButton(title: "Remove", target: self, action: #selector(remove))
        singleSelectionButtons = [copy, edit, pin, save]
        removeButton = remove
        status.font = .preferredFont(forTextStyle: .callout)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, remove, save, pin, edit, copy])
        footer.distribution = .fill
        footer.spacing = 8
        footer.setCustomSpacing(16, after: remove)
        let content = NSStackView(views: [scroll, footer])
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
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.center()
        refreshButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ values: [SessionCapture]) {
        let selected = Set(selectedIDs)
        records = values
        table.reloadData()
        let indices = IndexSet(records.indices.filter { selected.contains(records[$0].id) })
        if indices.isEmpty && !records.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            table.selectRowIndexes(indices, byExtendingSelection: false)
        }
        refreshButtons()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        if tableColumn?.identifier.rawValue == "preview" {
            let image = NSImageView(
                image: NSImage(
                    cgImage: record.image, size: CGSize(width: record.image.width, height: record.image.height)))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityLabel("Capture \(row + 1)")
            return image
        }
        let time = NSTextField(labelWithString: record.date.formatted(date: .omitted, time: .standard))
        time.font = .preferredFont(forTextStyle: .body)
        let size = NSTextField(labelWithString: "\(record.image.width) × \(record.image.height) pixels")
        size.font = .preferredFont(forTextStyle: .callout)
        size.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [time, size])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let cell = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshButtons() }
    private var selectedIDs: [UUID] {
        table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].id : nil }
    }
    private func refreshButtons() {
        let count = selectedIDs.count
        for button in singleSelectionButtons { button.isEnabled = count == 1 }
        removeButton?.isEnabled = count > 0
        status.stringValue = switch records.count {
        case 0: "No captures yet"
        case 1: "1 capture"
        default: "\(records.count) captures"
        }
    }
    private func act(_ action: RecentAction) {
        guard let id = selectedIDs.first, selectedIDs.count == 1 else { return }
        onAction(action, id)
    }
    @objc private func copyImage() { act(.copy) }
    @objc private func edit() { act(.edit) }
    @objc private func pin() { act(.pin) }
    @objc private func save() { act(.save) }
    @objc private func remove() { onDelete(selectedIDs) }
    func windowWillClose(_ notification: Notification) {
        records = []
        table.reloadData()
        onClose?()
    }
}

@MainActor
private final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickCaptureWindow: NSWindowController {
    private var expiry: Task<Void, Never>?
    var onClose: (() -> Void)?
    private let onAction: (RecentAction) -> Void
    private var isClosing = false
    init(image: CGImage, onAction: @escaping (RecentAction) -> Void) {
        self.onAction = onAction
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let panel = QuickCapturePanel(
            contentRect: CGRect(x: visible.maxX - 306, y: visible.minY + 16, width: 290, height: 204),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        let preview = PNGPromiseDragView(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        ) { makePNGFilePromiseProvider { try await pngDataOffMain(for: image) } }
        preview.toolTip = "Drag this capture out as a PNG"
        preview.wantsLayer = true
        preview.layer?.cornerRadius = CornerRadius.card
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.heightAnchor.constraint(equalToConstant: 132).isActive = true
        let edit = NSButton(title: "Edit", target: self, action: #selector(edit))
        let save = NSButton(title: "Export…", target: self, action: #selector(save))
        let pin = NSButton(title: "Pin", target: self, action: #selector(pin))
        let dismiss = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss") ?? NSImage(),
            target: self, action: #selector(dismiss))
        dismiss.isBordered = false
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.setAccessibilityLabel("Dismiss capture thumbnail")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [edit, save, pin, spacer, dismiss])
        actions.spacing = 8
        let content = NSStackView(views: [preview, actions])
        content.orientation = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        guard let window else { return }
        PanelTransition.present(window)
        expiry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
                try Task.checkCancellation()
                self?.close()
            } catch {}
        }
    }
    /// Callers see the thumbnail as gone at once; the panel itself fades out.
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
    @objc private func edit() {
        close()
        onAction(.edit)
    }
    @objc private func save() {
        close()
        onAction(.save)
    }
    @objc private func pin() {
        close()
        onAction(.pin)
    }
    @objc private func dismiss() { close() }
}
