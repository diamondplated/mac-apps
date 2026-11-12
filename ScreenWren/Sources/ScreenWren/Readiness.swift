import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ServiceManagement

enum ScreenCapturePermissionPhase: Equatable {
    case allowed
    case needsPermission
    case openSettings
    case needsRelaunch
}

func screenCapturePermissionPhase(
    isAllowed: Bool,
    wasRequested: Bool,
    requestGranted: Bool
) -> ScreenCapturePermissionPhase {
    if isAllowed { return .allowed }
    if requestGranted { return .needsRelaunch }
    return wasRequested ? .openSettings : .needsPermission
}

enum ShortcutCommand: String, CaseIterable, Codable {
    case capture
    case copyText
    case repeatCapture
    case frontWindow
    case freeze
    case recents
    case togglePins

    var identifier: UInt32 {
        switch self {
        case .capture: 1
        case .copyText: 2
        case .repeatCapture: 3
        case .frontWindow: 4
        case .freeze: 5
        case .recents: 6
        case .togglePins: 7
        }
    }

    var title: String {
        switch self {
        case .capture: "Capture Region or Window"
        case .copyText: "Copy Text from Region"
        case .repeatCapture: "Repeat Last Capture"
        case .frontWindow: "Capture Front Window"
        case .freeze: "Freeze Screen & Select"
        case .recents: "Browse Recent Captures"
        case .togglePins: "Hide / Restore All Pins"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .capture:
            Shortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey), keyEquivalent: "p", keyLabel: "P")
        case .copyText:
            Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey), keyEquivalent: "2", keyLabel: "2")
        case .repeatCapture:
            Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey | controlKey), keyEquivalent: "2", keyLabel: "2")
        case .recents:
            Shortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "p", keyLabel: "P")
        case .togglePins:
            Shortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey), keyEquivalent: "p", keyLabel: "P")
        case .frontWindow, .freeze:
            nil
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable {
    struct KeyCombination: Hashable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let keyLabel: String

    var keyCombination: KeyCombination {
        KeyCombination(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayName: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var hasRequiredModifier: Bool {
        !modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        guard let key = shortcutKey(for: event) else { return nil }
        return Shortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            keyEquivalent: key.equivalent,
            keyLabel: key.label
        )
    }
}

func conflictingShortcutCommands(
    _ values: [ShortcutCommand: Shortcut?]
) -> Set<ShortcutCommand> {
    var commandsByShortcut: [Shortcut.KeyCombination: [ShortcutCommand]] = [:]
    for (command, optionalShortcut) in values {
        guard let shortcut = optionalShortcut else { continue }
        commandsByShortcut[shortcut.keyCombination, default: []].append(command)
    }
    return Set(commandsByShortcut.values.filter { $0.count > 1 }.flatMap { $0 })
}

private func shortcutKey(for event: NSEvent) -> (equivalent: String, label: String)? {
    switch Int(event.keyCode) {
    case kVK_Return: return ("\r", "↩")
    case kVK_Tab: return ("\t", "⇥")
    case kVK_Space: return (" ", "Space")
    case kVK_Delete: return nil
    case kVK_ForwardDelete: return nil
    case kVK_LeftArrow: return (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), "←")
    case kVK_RightArrow: return (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), "→")
    case kVK_UpArrow: return (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), "↑")
    case kVK_DownArrow: return (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), "↓")
    default:
        guard let characters = event.charactersIgnoringModifiers,
              let character = characters.first,
              !character.isWhitespace,
              !character.isNewline else { return nil }
        let equivalent = String(character).lowercased()
        return (equivalent, String(character).uppercased())
    }
}

final class ShortcutStore {
    private let defaults: UserDefaults
    private let prefix = "shortcuts.v1."

    init(defaults: UserDefaults = .standard, preserveConfiguredDefaults: Bool = true) {
        self.defaults = defaults
        if preserveConfiguredDefaults { preserveConfiguredShortcuts() }
    }

    private func isConfigured(_ command: ShortcutCommand) -> Bool {
        defaults.object(forKey: prefix + command.rawValue + ".configured") != nil
    }

    private func preserveConfiguredShortcuts() {
        let savedKeys = Set(ShortcutCommand.allCases.filter(isConfigured).compactMap {
            shortcut(for: $0)?.keyCombination
        })
        for command in ShortcutCommand.allCases where !isConfigured(command) {
            if let shortcut = command.defaultShortcut, savedKeys.contains(shortcut.keyCombination) {
                // New defaults must not disable an existing user assignment on upgrade.
                set(nil, for: command)
            }
        }
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut? {
        let key = prefix + command.rawValue
        guard defaults.object(forKey: key + ".configured") != nil else {
            return command.defaultShortcut
        }
        guard defaults.bool(forKey: key + ".enabled"),
              let data = defaults.data(forKey: key + ".value") else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func set(_ shortcut: Shortcut?, for command: ShortcutCommand) {
        let key = prefix + command.rawValue
        defaults.set(true, forKey: key + ".configured")
        defaults.set(shortcut != nil, forKey: key + ".enabled")
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key + ".value")
        } else {
            defaults.removeObject(forKey: key + ".value")
        }
    }

    func restoreDefaults() {
        for command in ShortcutCommand.allCases {
            let key = prefix + command.rawValue
            defaults.removeObject(forKey: key + ".configured")
            defaults.removeObject(forKey: key + ".enabled")
            defaults.removeObject(forKey: key + ".value")
        }
    }
}

@MainActor
final class ShortcutManager: NSObject {
    typealias Action = @MainActor @Sendable () -> Void

    private let store: ShortcutStore
    private let actions: [ShortcutCommand: Action]
    private var registrations: [ShortcutCommand: HotKey] = [:]
    private let workspaceNotifications: NotificationCenter
    private(set) var failures: [ShortcutCommand: String] = [:]
    var onChange: (() -> Void)?

    init(store: ShortcutStore = ShortcutStore(), actions: [ShortcutCommand: Action]) {
        self.store = store
        self.actions = actions
        workspaceNotifications = NSWorkspace.shared.notificationCenter
        super.init()
        workspaceNotifications.addObserver(self, selector: #selector(retryUnavailableShortcuts),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(retryUnavailableShortcuts),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func registerAll() {
        registrations.removeAll()
        failures.removeAll()
        let values = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, store.shortcut(for: $0)) })
        let conflicts = conflictingShortcutCommands(values)

        for command in ShortcutCommand.allCases {
            guard let shortcut = values[command] ?? nil else { continue }
            guard !conflicts.contains(command) else {
                failures[command] = "Duplicates another ScreenWren shortcut"
                continue
            }
            guard let action = actions[command],
                  let registration = HotKey(
                    identifier: command.identifier,
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.carbonModifiers,
                    action: action
                  ) else {
                failures[command] = "Already used by macOS or another app"
                continue
            }
            registrations[command] = registration
        }
        onChange?()
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut? {
        store.shortcut(for: command)
    }

    /// Retry only failed commands; active shortcuts retain their Carbon registrations.
    @objc func retryUnavailableShortcuts() {
        guard !failures.isEmpty else { return }
        let values = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, store.shortcut(for: $0)) })
        let conflicts = conflictingShortcutCommands(values)
        var recovered = false
        for command in ShortcutCommand.allCases {
            guard failures[command] != nil, registrations[command] == nil,
                  !conflicts.contains(command),
                  let shortcut = values[command] ?? nil,
                  let action = actions[command],
                  let registration = HotKey(identifier: command.identifier, keyCode: shortcut.keyCode,
                      modifiers: shortcut.carbonModifiers, action: action) else { continue }
            registrations[command] = registration
            failures.removeValue(forKey: command)
            recovered = true
        }
        if recovered { onChange?() }
    }

    func update(_ command: ShortcutCommand, to shortcut: Shortcut?) -> String? {
        if let shortcut, !shortcut.hasRequiredModifier {
            return "Include Command, Control, or Option."
        }
        if let shortcut,
           ShortcutCommand.allCases.contains(where: {
               $0 != command && store.shortcut(for: $0)?.keyCombination == shortcut.keyCombination
           }) {
            return "That shortcut is already assigned in ScreenWren."
        }

        let previousShortcut = store.shortcut(for: command)
        registrations[command] = nil

        if let shortcut {
            guard let action = actions[command],
                  let registration = HotKey(
                    identifier: command.identifier,
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.carbonModifiers,
                    action: action
                  ) else {
                if let previousShortcut, let action = actions[command],
                   let restored = HotKey(
                        identifier: command.identifier,
                        keyCode: previousShortcut.keyCode,
                        modifiers: previousShortcut.carbonModifiers,
                        action: action
                   ) {
                    registrations[command] = restored
                    failures.removeValue(forKey: command)
                    onChange?()
                    return "macOS or another app did not make that shortcut available. Your previous shortcut is still active."
                }
                failures[command] = "Configured shortcut is unavailable"
                onChange?()
                return "That shortcut is unavailable, and the previous shortcut could not be restored. Choose another shortcut."
            }
            registrations[command] = registration
        }

        store.set(shortcut, for: command)
        failures.removeValue(forKey: command)
        onChange?()
        return nil
    }

    func restoreDefaults() {
        store.restoreDefaults()
        registerAll()
    }
}

@MainActor
final class LaunchAtLoginController {
    private let service = SMAppService.loginItem(identifier: "io.github.diamondplated.ScreenWren.LoginItem")

    var isEnabled: Bool { service.status == .enabled }

    var statusText: String {
        switch service.status {
        case .enabled: "On"
        case .notRegistered: "Off"
        case .requiresApproval: "Needs approval in System Settings"
        case .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    /// Repair must run from the installed main bundle so ServiceManagement resolves
    /// its embedded helper, rather than a stale build's login item.
    func repairRegistration() async throws {
        let bundle = Bundle.main
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/ScreenWrenLoginItem.app")
        let installedURL = URL(fileURLWithPath: "/Applications/ScreenWren.app")
        guard bundle.bundleURL.resolvingSymlinksInPath() == installedURL.resolvingSymlinksInPath(),
              bundle.bundleIdentifier == "io.github.diamondplated.ScreenWren",
              FileManager.default.fileExists(atPath: helperURL.path) else {
            throw NSError(domain: "ScreenWren.LoginItemRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Run --repair-login-item from /Applications/ScreenWren.app, with its embedded login helper."
            ])
        }

        if service.status != .notRegistered {
            // The synchronous variant returns before the old helper has exited.
            // Waiting here prevents re-registering while its removal is in flight.
            try await service.unregister()
        }
        try service.register()
        guard service.status == .enabled else {
            throw NSError(domain: "ScreenWren.LoginItemRepair", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Login item registration did not become enabled: \(statusText)."
            ])
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}

@MainActor
final class ShortcutRecorderField: NSTextField {
    var shortcut: Shortcut? { didSet { updateText() } }
    var onRecord: ((Shortcut?) -> String?)?
    var onMessage: ((String) -> Void)?

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = true
        drawsBackground = true
        alignment = .center
        font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
        focusRingType = .exterior
        toolTip = "Click, then type a shortcut. Delete clears it; Escape cancels."
        setAccessibilityRole(.textField)
        updateText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Type shortcut…"
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { stringValue = "Type shortcut…" }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        updateText()
        return result
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
        case kVK_Delete, kVK_ForwardDelete:
            if let message = onRecord?(nil) {
                onMessage?(message)
            } else {
                shortcut = nil
                onMessage?("Shortcut cleared. The menu command still works.")
                window?.makeFirstResponder(nil)
            }
        default:
            guard let proposed = Shortcut.from(event: event), proposed.hasRequiredModifier else {
                NSSound.beep()
                onMessage?("Include Command, Control, or Option.")
                return
            }
            if let message = onRecord?(proposed) {
                NSSound.beep()
                onMessage?(message)
            } else {
                shortcut = proposed
                onMessage?("Shortcut updated to \(proposed.displayName).")
                window?.makeFirstResponder(nil)
            }
        }
    }

    private func updateText() {
        stringValue = shortcut?.displayName ?? "None"
        setAccessibilityValue(stringValue)
    }
}

@MainActor
final class ReadinessWindowController: NSWindowController, NSWindowDelegate {
    private let shortcutManager: ShortcutManager
    private let launchAtLogin: LaunchAtLoginController
    private let accessCheck: () -> Bool
    private let accessRequest: () -> Bool
    private let settingsOpener: () -> Bool
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton()
    private let shortcutSummary = NSTextField(labelWithString: "")
    private let launchSwitch = NSSwitch()
    private let launchStatus = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private var permissionWasRequested = false
    private var permissionRequestGranted = false
    private var captureWasDenied = false
    private var dismissed = false

    var onTryCapture: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(
        shortcutManager: ShortcutManager,
        launchAtLogin: LaunchAtLoginController,
        accessCheck: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        accessRequest: @escaping () -> Bool = CGRequestScreenCaptureAccess,
        settingsOpener: @escaping () -> Bool = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return false }
            return NSWorkspace.shared.open(url)
        }
    ) {
        self.shortcutManager = shortcutManager
        self.launchAtLogin = launchAtLogin
        self.accessCheck = accessCheck
        self.accessRequest = accessRequest
        self.settingsOpener = settingsOpener
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: Self.contentWidth, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions & Shortcuts"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        let controller = makeContentController()
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.contentWidth, height: controller.view.fittingSize.height))
        window.center()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        dismissed = false
        refresh()
        showWindow(nil)
        window?.center()
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finishDismissal()
    }

    func capturePermissionWasDenied() {
        captureWasDenied = true
        permissionWasRequested = true
        refresh()
    }

    @objc private func requestOrOpenPermission() {
        if permissionPhase == .needsPermission {
            permissionWasRequested = true
            permissionRequestGranted = accessRequest()
            refresh()
            if permissionPhase == .allowed { return }
        }
        // A denied or previously answered system prompt may not appear again.
        // Always provide a real next step instead of leaving a dead Allow button.
        openScreenCaptureSettings()
    }

    @objc private func openScreenCaptureSettings() {
        guard settingsOpener() else {
            messageLabel.stringValue = "Open System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        messageLabel.stringValue = "Enable this copy of ScreenWren, then use Quit & Reopen."
    }

    @objc private func revealCurrentCopy() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(launchSwitch.state == .on)
            messageLabel.stringValue = launchAtLogin.isEnabled
                ? "ScreenWren will be ready after you sign in."
                : "Launch at login is off."
        } catch {
            NSSound.beep()
            messageLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    @objc private func restoreShortcuts() {
        shortcutManager.restoreDefaults()
        rebuildShortcutRows()
        refresh()
        messageLabel.stringValue = "Default shortcuts restored."
    }

    @objc private func dismissWindow() {
        window?.close()
    }

    @objc private func primaryAction() {
        switch permissionPhase {
        case .needsPermission, .openSettings, .needsRelaunch:
            relaunch()
            return
        case .allowed:
            break
        }
        finishDismissal()
        window?.orderOut(nil)
        onTryCapture?()
    }

    private var permissionPhase: ScreenCapturePermissionPhase {
        screenCapturePermissionPhase(
            isAllowed: !captureWasDenied && accessCheck(),
            wasRequested: permissionWasRequested,
            requestGranted: permissionRequestGranted
        )
    }

    @objc private func relaunch() {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/ScreenWrenLoginItem.app/Contents/MacOS/ScreenWrenLoginItem")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSSound.beep()
            messageLabel.stringValue = "Quit and reopen ScreenWren to finish permission setup."
            return
        }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--relaunch", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
            messageLabel.stringValue = "Quit and reopen ScreenWren to finish permission setup."
        }
    }

    @objc private func refresh() {
        let phase = permissionPhase
        let allowed = phase == .allowed
        let symbol = allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        permissionIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: allowed ? "Allowed" : "Required")
        permissionIcon.contentTintColor = allowed ? .systemGreen : .systemOrange
        permissionStatus.stringValue = switch phase {
        case .allowed: "Allowed"
        case .needsPermission, .openSettings: "Not available to this copy"
        case .needsRelaunch: "Restart to recheck access"
        }
        permissionStatus.textColor = allowed ? .systemGreen : .systemOrange
        permissionButton.title = "Open Screen Recording Settings"

        let active = ShortcutCommand.allCases.filter { shortcutManager.shortcut(for: $0) != nil }.count
        if shortcutManager.failures.isEmpty {
            shortcutSummary.stringValue = "\(active) of \(ShortcutCommand.allCases.count) shortcuts active"
            shortcutSummary.textColor = .secondaryLabelColor
        } else {
            shortcutSummary.stringValue = "\(shortcutManager.failures.count) shortcut\(shortcutManager.failures.count == 1 ? "" : "s") unavailable"
            shortcutSummary.textColor = .systemOrange
        }

        launchSwitch.state = launchAtLogin.isEnabled ? .on : .off
        launchStatus.stringValue = launchAtLogin.statusText
        primaryButton.title = switch phase {
        case .allowed: "Start Capture"
        case .needsPermission, .openSettings, .needsRelaunch: "Quit & Reopen ScreenWren"
        }
        secondaryButton.title = allowed ? "Done" : "Not Now"
    }

    static let contentWidth: CGFloat = 560

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let content = NSView()
        controller.view = content

        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionIcon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        permissionStatus.font = font(.callout, weight: .semibold)
        let permissionStatusRow = NSStackView(views: [permissionIcon, permissionStatus])
        permissionStatusRow.spacing = 4
        permissionButton.target = self
        permissionButton.action = #selector(requestOrOpenPermission)
        permissionButton.bezelStyle = .rounded
        let permissionNote = label("Enable this copy, then quit and reopen. Still images only, never audio.",
                                   style: .callout, color: .secondaryLabelColor)
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealCurrentCopy))
        revealButton.toolTip = "Show this copy of ScreenWren, the one System Settings must allow"
        let checkButton = NSButton(title: "Check Again", target: self, action: #selector(refresh))
        let permissionSpacer = NSView()
        permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let permissionActions = NSStackView(views: [revealButton, checkButton, permissionSpacer, permissionButton])
        permissionActions.distribution = .fill
        permissionActions.spacing = 8
        let permissionCard = card(
            header: label("Screen & System Audio Recording", style: .headline),
            accessory: permissionStatusRow,
            body: [permissionNote, permissionActions])

        let shortcutRows = NSStackView()
        shortcutRows.identifier = NSUserInterfaceItemIdentifier("ShortcutRows")
        shortcutRows.orientation = .vertical
        shortcutRows.spacing = 6
        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcuts))
        shortcutSummary.font = font(.callout)
        shortcutSummary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let restoreRow = NSStackView(views: [shortcutSummary, restoreButton])
        restoreRow.distribution = .fill
        let shortcutCard = card(
            header: label("Keyboard Shortcuts", style: .headline),
            accessory: nil,
            body: [shortcutRows, restoreRow])

        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin)
        launchSwitch.controlSize = .small
        launchStatus.font = font(.callout)
        launchStatus.textColor = .secondaryLabelColor
        let launchTrailing = NSStackView(views: [launchStatus, launchSwitch])
        launchTrailing.spacing = 8
        let launchCard = card(header: label("Launch at Login", style: .headline), accessory: launchTrailing, body: [])

        let privacy = label("Captures never leave this Mac. Recents clear when ScreenWren quits.",
                            style: .callout, color: .secondaryLabelColor)

        messageLabel.font = font(.callout)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryButton.title = "Not Now"
        secondaryButton.target = self
        secondaryButton.action = #selector(dismissWindow)
        secondaryButton.keyEquivalent = "\u{1b}"
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [messageLabel, secondaryButton, primaryButton])
        footer.distribution = .fill
        footer.spacing = 8

        let stack = NSStackView(views: [permissionCard, shortcutCard, launchCard, privacy, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: privacy)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutRows.widthAnchor.constraint(equalTo: restoreRow.widthAnchor),
        ])

        rebuildShortcutRows(in: shortcutRows)
        refresh()
        return controller
    }

    private func rebuildShortcutRows() {
        guard let root = window?.contentViewController?.view,
              let rows = findView(identifier: "ShortcutRows", in: root) as? NSStackView else { return }
        rebuildShortcutRows(in: rows)
    }

    private func rebuildShortcutRows(in rows: NSStackView) {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for command in ShortcutCommand.allCases {
            let name = label(command.title, style: .body)
            let recorder = ShortcutRecorderField(shortcut: shortcutManager.shortcut(for: command))
            recorder.setAccessibilityLabel("\(command.title) shortcut")
            recorder.onRecord = { [weak self] shortcut in
                self?.shortcutManager.update(command, to: shortcut)
            }
            recorder.onMessage = { [weak self] message in
                self?.messageLabel.stringValue = message
                self?.refresh()
            }
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 112).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true

            let row = NSStackView(views: [name, recorder])
            row.orientation = .horizontal
            row.distribution = .fill
            row.alignment = .centerY
            row.spacing = 10
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            recorder.setContentHuggingPriority(.required, for: .horizontal)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    /// A grouped card: a header row (title and optional trailing accessory) over its body rows.
    /// The fill and border resolve in `updateLayer`, so they follow light and dark mode live.
    private func card(header: NSView, accessory: NSView?, body: [NSView]) -> NSView {
        let container = SemanticLayerView(
            fill: .quaternarySystemFill, border: .separatorColor, borderWidth: 1, cornerRadius: CornerRadius.card)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        var headerViews = [header]
        if let accessory {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            headerViews += [spacer, accessory]
        }
        let headerRow = NSStackView(views: headerViews)
        headerRow.distribution = .fill
        headerRow.spacing = 8
        let column = NSStackView(views: [headerRow] + body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            headerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        for view in body where view is NSStackView {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return container
    }

    private func font(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    private func label(_ text: String, style: NSFont.TextStyle, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .preferredFont(forTextStyle: style)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.findView(identifier: identifier, in: $0) }.first
    }

    private func finishDismissal() {
        guard !dismissed else { return }
        dismissed = true
        onDismiss?()
    }
}
