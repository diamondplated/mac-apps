import AppKit
import ApplicationServices
import ServiceManagement
import StayLitCore

final class Preferences {
    static let identifier = "com.andrew.staylit"
    static let changed = Notification.Name("com.andrew.mactools.settingsChanged")
    static let statusRequest = Notification.Name("com.andrew.staylit.statusRequest")
    static let statusReply = Notification.Name("com.andrew.staylit.statusReply")
    let defaults = UserDefaults.standard
    var store: SettingsStore { SettingsStore(defaults: defaults) }

    var settings: StayLitSettings {
        defaults.synchronize()
        return store.settings
    }

    func apply(_ patch: SettingsPatch) throws {
        if let login = patch.values["launchAtLogin"] as? Bool {
            let service = SMAppService.mainApp
            if login && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            else if !login && service.status != .notRegistered { try service.unregister() }
        }
        store.write(patch)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: Self.identifier, userInfo: nil, deliverImmediately: true)
    }

    /// The running app's live state: its permissions, the sentence the menu shows, and
    /// the displays it has read. Falls back to this process's own checks when no single
    /// copy at this bundle path answers within half a second.
    private func runtimeStatus() -> (status: [String: Any], source: String) {
        // StayLit not running means nothing is keeping the Mac awake.
        var base: [String: Any] {
            ["permissions": ["accessibility": AXIsProcessTrusted()], "awakeReason": NSNull(),
             "externalDisplays": DisplayController.staticExternalDisplays()]
        }
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Self.identifier && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let ownURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = applications.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == ownURL }
        guard matches.count == 1, let app = matches.first else { return (base, "currentProcess") }
        let token = UUID().uuidString
        var reply: [String: Any]?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Self.statusReply, object: token, queue: nil) { notification in
            guard let info = notification.userInfo, (info["pid"] as? NSNumber)?.int32Value == app.processIdentifier,
                  let permissions = info["permissions"] as? [String: Bool], let displays = info["externalDisplays"] as? [[String: Any]] else { return }
            reply = ["permissions": permissions, "awakeReason": info["awakeReason"] as? String ?? NSNull(), "externalDisplays": displays]
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(Self.statusRequest, object: Self.identifier, userInfo: ["token": token], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(0.5)
        while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if let reply { return (reply, "runningApp") }
        return (base, "currentProcess")
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
        let (runtime, source) = runtimeStatus()
        var result: [String: Any] = ["schemaVersion": 1, "app": "stayLit", "launchAtLogin": status == "enabled", "loginStatus": status,
                                     "permissionsSource": source]
        result.merge(store.snapshotValues()) { _, new in new }
        result.merge(runtime) { _, new in new }
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
