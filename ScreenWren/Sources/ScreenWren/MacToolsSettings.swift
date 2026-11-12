import AppKit
import Carbon
import CoreGraphics

enum SettingsOpenOutcome: Equatable {
    case settingsPage
    case manager(URL)
    case managerMissing
}

/// ScreenWren keeps no settings window of its own: its settings are a page in Mac Tools.
/// A manager that predates the page link can't open it, so it is launched instead, and a
/// missing manager is explained.
@MainActor @discardableResult
func openScreenWrenSettings(
    openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) },
    managerCandidates: [URL] = [
        URL(fileURLWithPath: "/Applications/Mac Tools.app"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Mac Tools.app"),
    ],
    managerExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    launchManager: (URL) -> Void = { NSWorkspace.shared.openApplication(at: $0, configuration: .init()) },
    reportMissingManager: () -> Void = {
        let alert = NSAlert()
        alert.messageText = "Install Mac Tools to manage ScreenWren"
        alert.informativeText = "Place Mac Tools in Applications, then open it to change ScreenWren settings."
        alert.runModal()
    }
) -> SettingsOpenOutcome {
    if openURL(MacToolsSettingsBridge.settingsPageURL) { return .settingsPage }
    if let manager = managerCandidates.first(where: managerExists) {
        launchManager(manager)
        return .manager(manager)
    }
    reportMissingManager()
    return .managerMissing
}

/// Native preference access for the suite manager. No capture or application UI is started.
@MainActor
struct MacToolsSettingsBridge {
    static let notification = Notification.Name("com.andrew.mactools.settingsChanged")
    static let bundleIdentifier = "io.github.diamondplated.ScreenWren"
    /// ScreenWren's page in the Mac Tools manager. Managers older than this link can't open it.
    static let settingsPageURL = URL(string: "mactools://app/screenWren")!
    static let statusRequest = Notification.Name("com.andrew.screenwren.statusRequest")
    static let statusReply = Notification.Name("com.andrew.screenwren.statusReply")

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ShortcutValue: Codable {
        let command: ShortcutCommand
        let title: String
        let shortcut: Shortcut?

        enum CodingKeys: String, CodingKey { case command, title, shortcut }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
            try container.encode(title, forKey: .title)
            try container.encode(shortcut, forKey: .shortcut)
        }
    }

    struct Snapshot: Codable {
        let schemaVersion: Int
        let app: String
        let launchAtLogin: Bool
        let loginStatus: String
        let captureDestination: CaptureDestination
        let showsThumbnail: Bool
        let adjustBeforeCapture: Bool
        let selectionWidth: Int
        let selectionHeight: Int
        let aspectRatio: Double
        let presets: [SelectionPreset]
        let shortcuts: [ShortcutValue]
        let permissions: [String: Bool]
        /// `runningApp` when the running ScreenWren answered; `currentProcess` when this helper
        /// answered for itself, which macOS may attribute to the manager that started it.
        let permissionsSource: String
    }

    struct Patch: Decodable {
        let launchAtLogin: Bool?
        let captureDestination: CaptureDestination?
        let showsThumbnail: Bool?
        let adjustBeforeCapture: Bool?
        let selectionWidth: Int?
        let selectionHeight: Int?
        let aspectRatio: Double?
        let presets: [SelectionPreset]?
        let shortcuts: [ShortcutValue]?
        let resetShortcuts: Bool?
    }

    let defaults: UserDefaults
    let loginState: () -> (enabled: Bool, status: String)
    let setLoginEnabled: (Bool) throws -> Void
    let notify: (Bool) -> Void
    let permissionState: () -> [String: Bool]
    let runningAppPermissions: () -> [String: Bool]?

    init(defaults: UserDefaults, loginState: @escaping () -> (enabled: Bool, status: String),
         setLoginEnabled: @escaping (Bool) throws -> Void, notify: @escaping (Bool) -> Void = { _ in },
         permissionState: @escaping () -> [String: Bool] = { ["screenRecording": CGPreflightScreenCaptureAccess()] },
         runningAppPermissions: @escaping () -> [String: Bool]? = { nil }) {
        self.defaults = defaults
        self.loginState = loginState
        self.setLoginEnabled = setLoginEnabled
        self.notify = notify
        self.permissionState = permissionState
        self.runningAppPermissions = runningAppPermissions
    }

    struct RunningCopy {
        let processIdentifier: pid_t
        let bundleURL: URL?
    }

    /// The running copy to ask: exactly one other process started from this same bundle.
    /// None, or several (an ambiguous answer), leaves the helper reporting for itself.
    static func runningCopyToAsk(_ copies: [RunningCopy], ownBundleURL: URL, ownProcessIdentifier: pid_t) -> pid_t? {
        let own = ownBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = copies.filter {
            $0.processIdentifier != ownProcessIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == own
        }
        return matches.count == 1 ? matches[0].processIdentifier : nil
    }

    private final class ReplyBox: @unchecked Sendable { var permissions: [String: Bool]? }

    /// Asks the running app for its permission state and waits briefly for the reply.
    static func askRunningApp(processIdentifier: pid_t, timeout: TimeInterval = 0.5,
                              center: DistributedNotificationCenter = .default()) -> [String: Bool]? {
        let token = UUID().uuidString
        let reply = ReplyBox()
        let observer = center.addObserver(forName: statusReply, object: token, queue: nil) { notification in
            guard let info = notification.userInfo,
                  (info["pid"] as? NSNumber)?.int32Value == processIdentifier,
                  let permissions = info["permissions"] as? [String: Bool] else { return }
            reply.permissions = permissions
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(statusRequest, object: bundleIdentifier, userInfo: ["token": token],
                                    deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while reply.permissions == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return reply.permissions
    }

    /// Installed by the running app so the manager's helper can report its real permission state.
    static func answerStatusRequests(center: DistributedNotificationCenter = .default(),
                                     permissions: @escaping @Sendable () -> [String: Bool]) -> NSObjectProtocol {
        center.addObserver(forName: statusRequest, object: bundleIdentifier, queue: .main) { notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            center.postNotificationName(statusReply, object: token, userInfo: [
                "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                "permissions": permissions(),
            ], deliverImmediately: true)
        }
    }

    static func isInstalledBundle(_ url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let roots = [URL(fileURLWithPath: "/Applications"), homeDirectory.appendingPathComponent("Applications")]
            .map { $0.resolvingSymlinksInPath().path }
        return resolved.pathExtension == "app" && roots.contains(resolved.deletingLastPathComponent().path)
    }

    static func live() -> Self {
        let login = LaunchAtLoginController()
        return Self(defaults: .standard, loginState: { (login.isEnabled, login.statusText) },
                    setLoginEnabled: { enabled in
            let bundle = Bundle.main
            let helper = bundle.bundleURL.appendingPathComponent("Contents/Library/LoginItems/ScreenWrenLoginItem.app")
            guard isInstalledBundle(bundle.bundleURL), bundle.bundleIdentifier == bundleIdentifier,
                  Bundle(url: helper)?.bundleIdentifier == bundleIdentifier + ".LoginItem" else {
                throw Failure(message: "Change launch at login from ScreenWren installed in /Applications or ~/Applications, with its embedded login helper.")
            }
            try login.setEnabled(enabled)
        }, notify: { shortcutsChanged in
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: bundleIdentifier, userInfo: ["shortcutsChanged": shortcutsChanged], deliverImmediately: true)
        }, runningAppPermissions: {
            let copies = NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
                .map { RunningCopy(processIdentifier: $0.processIdentifier, bundleURL: $0.bundleURL) }
            guard let processIdentifier = runningCopyToAsk(
                copies, ownBundleURL: Bundle.main.bundleURL,
                ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier) else { return nil }
            return askRunningApp(processIdentifier: processIdentifier)
        })
    }

    func snapshot() -> Snapshot {
        defaults.synchronize()
        let preferences = WorkflowPreferences(defaults: defaults)
        let shortcuts = ShortcutStore(defaults: defaults, preserveConfiguredDefaults: false)
        let login = loginState()
        let live = runningAppPermissions()?["screenRecording"].map { ["screenRecording": $0] }
        return Snapshot(schemaVersion: 1, app: "screenWren", launchAtLogin: login.enabled,
                        loginStatus: login.status, captureDestination: preferences.destination,
                        showsThumbnail: preferences.showsThumbnail, adjustBeforeCapture: preferences.adjustBeforeCapture,
                        selectionWidth: preferences.fixedSize.map { Int($0.width) } ?? 0,
                        selectionHeight: preferences.fixedSize.map { Int($0.height) } ?? 0,
                        aspectRatio: preferences.aspectRatio.map(Double.init) ?? 0, presets: preferences.presets,
                        shortcuts: ShortcutCommand.allCases.map {
            ShortcutValue(command: $0, title: $0.title, shortcut: shortcuts.shortcut(for: $0))
        }, permissions: live ?? permissionState(),
           permissionsSource: live == nil ? "currentProcess" : "runningApp")
    }

    private func validateKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String> = []) throws {
        guard Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else {
            throw Failure(message: "Unknown or missing settings fields.")
        }
    }

    func write(_ data: Data) throws -> Snapshot {
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Settings must be a JSON object of at most 64 KiB.")
        }
        try validateKeys(object, allowed: ["launchAtLogin", "captureDestination", "showsThumbnail",
            "adjustBeforeCapture", "selectionWidth", "selectionHeight", "aspectRatio", "presets", "shortcuts", "resetShortcuts"])
        guard !object.values.contains(where: { $0 is NSNull }) else {
            throw Failure(message: "Settings fields cannot be null.")
        }
        if let presets = object["presets"] as? [[String: Any]] {
            for preset in presets {
                try validateKeys(preset, allowed: ["name", "width", "height"], required: ["name", "width", "height"])
            }
        }
        if let shortcuts = object["shortcuts"] as? [[String: Any]] {
            for entry in shortcuts {
                try validateKeys(entry, allowed: ["command", "title", "shortcut"], required: ["command", "title", "shortcut"])
                if let shortcut = entry["shortcut"] as? [String: Any] {
                    let keys: Set<String> = ["keyCode", "carbonModifiers", "keyEquivalent", "keyLabel"]
                    try validateKeys(shortcut, allowed: keys, required: keys)
                }
            }
        }
        let patch = try JSONDecoder().decode(Patch.self, from: data)
        let preferences = WorkflowPreferences(defaults: defaults)
        let width = patch.selectionWidth ?? preferences.fixedSize.map { Int($0.width) } ?? 0
        let height = patch.selectionHeight ?? preferences.fixedSize.map { Int($0.height) } ?? 0
        guard (width == 0 && height == 0) || ((4...16_000).contains(width) && (4...16_000).contains(height)) else {
            throw Failure(message: "Selection width and height must both be 0, or each between 4 and 16000.")
        }
        if let ratio = patch.aspectRatio, !(ratio == 0 || (ratio.isFinite && (0.01...100).contains(ratio))) {
            throw Failure(message: "Aspect ratio must be 0 or between 0.01 and 100.")
        }
        if let presets = patch.presets {
            let names = presets.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard presets.count <= 20, presets.allSatisfy({ $0.isValid && $0.name.count <= 80 &&
                !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  Set(names).count == names.count else {
                throw Failure(message: "Use at most 20 presets with unique names and dimensions from 4 to 16000.")
            }
        }
        if patch.resetShortcuts == true && patch.shortcuts != nil {
            throw Failure(message: "Do not combine resetShortcuts and shortcuts.")
        }
        if let shortcuts = patch.shortcuts {
            guard Set(shortcuts.map(\.command)).count == shortcuts.count else {
                throw Failure(message: "Include each shortcut command at most once.")
            }
            let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
            for entry in shortcuts {
                guard let value = entry.shortcut else { continue }
                guard value.keyCode <= 127, value.hasRequiredModifier,
                      value.carbonModifiers & ~allowed == 0,
                      !value.keyEquivalent.isEmpty, value.keyEquivalent.count <= 2,
                      !value.keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.keyLabel.count <= 32 else {
                    throw Failure(message: "Invalid shortcut for \(entry.command.title).")
                }
            }
            let store = ShortcutStore(defaults: defaults, preserveConfiguredDefaults: false)
            var values = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, store.shortcut(for: $0)) })
            for entry in shortcuts { values.updateValue(entry.shortcut, forKey: entry.command) }
            guard conflictingShortcutCommands(values).isEmpty else {
                throw Failure(message: "Shortcut key combinations must be unique.")
            }
        }
        // ServiceManagement is the only fallible write. Validate the entire patch first,
        // then change it before preferences so a rejected login operation writes no defaults.
        if let enabled = patch.launchAtLogin { try setLoginEnabled(enabled) }
        if let value = patch.captureDestination { preferences.destination = value }
        if let value = patch.showsThumbnail { preferences.showsThumbnail = value }
        if let value = patch.adjustBeforeCapture { preferences.adjustBeforeCapture = value }
        if patch.selectionWidth != nil || patch.selectionHeight != nil {
            preferences.fixedSize = width == 0 ? nil : CGSize(width: width, height: height)
        }
        if let value = patch.aspectRatio { preferences.aspectRatio = value == 0 ? nil : value }
        if let value = patch.presets { preferences.presets = value }
        if let values = patch.shortcuts {
            let store = ShortcutStore(defaults: defaults, preserveConfiguredDefaults: false)
            for value in values { store.set(value.shortcut, for: value.command) }
        }
        if patch.resetShortcuts == true {
            ShortcutStore(defaults: defaults, preserveConfiguredDefaults: false).restoreDefaults()
        }
        defaults.synchronize()
        notify(patch.shortcuts != nil || patch.resetShortcuts == true)
        return snapshot()
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.contains("--mac-tools-settings") else { return false }
        do {
            guard arguments.count == 3, arguments[1] == "--mac-tools-settings",
                  ["read", "write"].contains(arguments[2]) else {
                throw Failure(message: "Usage: --mac-tools-settings read|write")
            }
            let bridge = live()
            let value: Snapshot
            if arguments[2] == "read" { value = bridge.snapshot() }
            else {
                var data = Data()
                while data.count <= 65_536 {
                    let chunk = try FileHandle.standardInput.read(upToCount: min(4096, 65_537 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                value = try bridge.write(data)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(value))
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("ScreenWren settings: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
        return true
    }
}
