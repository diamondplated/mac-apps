import AppKit
import ServiceManagement
import MixBarCore

final class Preferences {
    static let identifier = "com.andrew.mixbar"
    static let changed = Notification.Name("com.andrew.mactools.settingsChanged")
    static let statusRequest = Notification.Name("com.andrew.mixbar.statusRequest")
    static let statusReply = Notification.Name("com.andrew.mixbar.statusReply")
    /// The running app's own memory of what it learned about audio capture. Not a bridge key.
    static let learnedCaptureStatusKey = "learnedAudioCaptureStatus"
    let defaults = UserDefaults.standard
    var store: SettingsStore { SettingsStore(defaults: defaults) }

    var settings: MixBarSettings {
        defaults.synchronize()
        return store.settings
    }

    /// Process taps exist from macOS 14.2. The bridge answers this without touching Core Audio.
    static var audioControlAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// The name an app shows under in Mac Tools when MixBar first saves a setting for it.
    static func installedName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func apply(_ patch: SettingsPatch, nameFor: (String) -> String? = Preferences.installedName) throws {
        if let login = patch.values["launchAtLogin"] as? Bool {
            let service = SMAppService.mainApp
            if login && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            else if !login && service.status != .notRegistered { try service.unregister() }
        }
        store.write(patch, nameFor: nameFor)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: Self.identifier, userInfo: nil, deliverImmediately: true)
    }

    /// The running app's capture status, matched by PID and bundle path. `unknown` when
    /// no single copy at this bundle path answers within half a second.
    private func runningCaptureStatus() -> CaptureStatus {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Self.identifier && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let ownURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = applications.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == ownURL }
        guard matches.count == 1, let app = matches.first else { return .unknown }
        let token = UUID().uuidString
        var reply: CaptureStatus?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Self.statusReply, object: token, queue: nil) { notification in
            guard let info = notification.userInfo, (info["pid"] as? NSNumber)?.int32Value == app.processIdentifier,
                  let raw = info["audioCaptureStatus"] as? String, let status = CaptureStatus(rawValue: raw) else { return }
            reply = status
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(Self.statusRequest, object: Self.identifier, userInfo: ["token": token], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(0.5)
        while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return reply ?? .unknown
    }

    var snapshot: [String: Any] {
        let status: String
        switch SMAppService.mainApp.status {
        case .enabled: status = "enabled"
        case .notRegistered: status = "notRegistered"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        @unknown default: status = "unknown"
        }
        defaults.synchronize()
        var result: [String: Any] = ["schemaVersion": 1, "app": "mixBar", "launchAtLogin": status == "enabled", "loginStatus": status,
                                     "audioControlAvailable": Self.audioControlAvailable,
                                     "audioCaptureStatus": runningCaptureStatus().rawValue]
        result.merge(store.snapshotValues()) { _, new in new }
        return result
    }

    static func runCommand(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 2, ["read", "write"].contains(arguments[1]) else { throw SettingsError.invalid("Usage: --mac-tools-settings read|write") }
            let preferences = Preferences()
            if arguments[1] == "write" {
                try preferences.apply(SettingsPatch(data: FileHandle.standardInput.readDataToEndOfFile()))
            }
            var data = try JSONSerialization.data(withJSONObject: preferences.snapshot, options: [.sortedKeys])
            data.append(10)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1
        }
    }
}
