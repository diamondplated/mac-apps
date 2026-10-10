import Foundation
import CoreFoundation
import ServiceManagement

struct DockPeekSettingsSnapshot: Encodable {
    let schemaVersion = 1
    let app = "dockPeek"
    let launchAtLogin: Bool
    let loginStatus: String
    let previewsEnabled: Bool
    let showsTabs: Bool
    let dismissalDelay: Double
}

struct DockPeekSettingsPatch {
    let launchAtLogin: Bool?
    let previewsEnabled: Bool?
    let showsTabs: Bool?
    let dismissalDelay: Double?

    init(data: Data) throws {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalid("Expected a JSON object.")
        }
        let supported: Set<String> = ["launchAtLogin", "previewsEnabled", "showsTabs", "dismissalDelay"]
        guard Set(values.keys).isSubset(of: supported) else {
            throw SettingsError.invalid("Unknown or read-only setting.")
        }
        func bool(_ key: String) throws -> Bool? {
            guard let value = values[key] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw SettingsError.invalid("\(key) must be a Boolean.")
            }
            return number.boolValue
        }
        launchAtLogin = try bool("launchAtLogin")
        previewsEnabled = try bool("previewsEnabled")
        showsTabs = try bool("showsTabs")
        if let value = values["dismissalDelay"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0.1...3.0).contains(number.doubleValue) else {
                throw SettingsError.invalid("dismissalDelay must be a number between 0.1 and 3 seconds.")
            }
            dismissalDelay = number.doubleValue
        } else {
            dismissalDelay = nil
        }
    }
}

enum SettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

final class ToolPreferences {
    static let shared = ToolPreferences()
    static let changedNotification = Notification.Name("com.andrew.mactools.settingsChanged")
    static let bundleIdentifier = "com.andrew.dockpeek"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var previewsEnabled: Bool { defaults.object(forKey: "previewsEnabled") as? Bool ?? true }
    var showsTabs: Bool { defaults.object(forKey: "showsTabs") as? Bool ?? true }
    var dismissalDelay: Double {
        guard let value = defaults.object(forKey: "dismissalDelay") as? Double,
              value.isFinite, (0.1...3.0).contains(value) else { return 0.6 }
        return value
    }

    func synchronize() { defaults.synchronize() }

    func snapshot(loginStatus: SMAppService.Status = SMAppService.mainApp.status) -> DockPeekSettingsSnapshot {
        let status: String
        switch loginStatus {
        case .enabled: status = "enabled"
        case .notRegistered: status = "notRegistered"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        @unknown default: status = "unknown"
        }
        return DockPeekSettingsSnapshot(
            launchAtLogin: loginStatus == .enabled, loginStatus: status,
            previewsEnabled: previewsEnabled, showsTabs: showsTabs, dismissalDelay: dismissalDelay
        )
    }

    func apply(_ patch: DockPeekSettingsPatch, setLogin: (Bool) throws -> Void) throws {
        // Complete validation happens when constructing the patch. Perform the only
        // fallible mutation before committing behavior preferences.
        if let enabled = patch.launchAtLogin { try setLogin(enabled) }
        if let value = patch.previewsEnabled { defaults.set(value, forKey: "previewsEnabled") }
        if let value = patch.showsTabs { defaults.set(value, forKey: "showsTabs") }
        if let value = patch.dismissalDelay { defaults.set(value, forKey: "dismissalDelay") }
        defaults.synchronize()
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled && service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func runSettingsCommand(arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 2, ["read", "write"].contains(arguments[1]) else {
                throw SettingsError.invalid("Usage: --mac-tools-settings read|write")
            }
            if arguments[1] == "write" {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 65_536 else { throw SettingsError.invalid("Settings patch is too large.") }
                let patch = try DockPeekSettingsPatch(data: input)
                try shared.apply(patch, setLogin: setLaunchAtLogin)
                DistributedNotificationCenter.default().postNotificationName(
                    changedNotification, object: bundleIdentifier, userInfo: nil, deliverImmediately: true
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var result = try encoder.encode(shared.snapshot())
            result.append(0x0A)
            FileHandle.standardOutput.write(result)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
