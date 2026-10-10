import AppKit
import ApplicationServices
import ServiceManagement
import ScrollSplitCore

final class Preferences {
    static let identifier = "com.andrew.scrollsplit"
    static let changed = Notification.Name("com.andrew.mactools.settingsChanged")
    let defaults = UserDefaults.standard
    var settings: ScrollSettings {
        defaults.synchronize()
        var value = ScrollSettings()
        value.enabled = defaults.bool(forKey: "enabled")
        value.reverseVertical = defaults.object(forKey: "reverseVertical") as? Bool ?? true
        value.reverseHorizontal = defaults.bool(forKey: "reverseHorizontal")
        let speed = defaults.object(forKey: "speedMultiplier") as? Double ?? 1
        value.speedMultiplier = speed.isFinite && (0.25...4).contains(speed) ? speed : 1
        return value
    }
    func apply(_ patch: SettingsPatch) throws {
        if let login = patch.values["launchAtLogin"] as? Bool {
            let service = SMAppService.mainApp
            if login && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            else if !login && service.status != .notRegistered { try service.unregister() }
        }
        for (key, value) in patch.values where key != "launchAtLogin" { defaults.set(value, forKey: key) }
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: Self.identifier, userInfo: nil, deliverImmediately: true)
    }
    static let statusRequest = Notification.Name("com.andrew.scrollsplit.statusRequest")
    static let statusReply = Notification.Name("com.andrew.scrollsplit.statusReply")
    private func runtimePermissions() -> ([String: Bool], String) {
        let base = ["accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess()]
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Self.identifier && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let ownURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = applications.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == ownURL }
        guard matches.count == 1, let app = matches.first else {
            if applications.isEmpty { return (base.merging(["eventTapActive": false]) { _, new in new }, "notRunning") }
            return (base, matches.isEmpty ? "differentCopyRunning" : "ambiguousCopies")
        }
        let token = UUID().uuidString
        var reply: [String: Bool]?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Self.statusReply, object: token, queue: nil) { notification in
            guard let info = notification.userInfo, (info["pid"] as? NSNumber)?.int32Value == app.processIdentifier,
                  let permissions = info["permissions"] as? [String: Bool] else { return }
            reply = permissions
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(Self.statusRequest, object: Self.identifier, userInfo: ["token": token], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(0.5)
        while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return (reply ?? base, reply == nil ? "unknown" : "checked")
    }
    var snapshot: [String: Any] {
        let s = settings
        let status: String
        switch SMAppService.mainApp.status {
        case .enabled: status = "enabled"
        case .notRegistered: status = "notRegistered"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        @unknown default: status = "unknown"
        }
        let (permissions, tapStatus) = runtimePermissions()
        return ["schemaVersion": 1, "app": "scrollSplit", "launchAtLogin": status == "enabled", "loginStatus": status,
                "enabled": s.enabled, "reverseVertical": s.reverseVertical, "reverseHorizontal": s.reverseHorizontal, "speedMultiplier": s.speedMultiplier,
                "permissions": permissions, "eventTapStatus": tapStatus, "permissionsSource": tapStatus == "checked" ? "runningApp" : "currentProcess"]
    }
    static func runCommand(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 2, ["read", "write"].contains(arguments[1]) else { throw SettingsError.invalid("Usage: --mac-tools-settings read|write") }
            let preferences = Preferences()
            if arguments[1] == "write" { try preferences.apply(SettingsPatch(data: FileHandle.standardInput.readDataToEndOfFile())) }
            var data = try JSONSerialization.data(withJSONObject: preferences.snapshot, options: [.sortedKeys])
            data.append(10)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1
        }
    }
}
