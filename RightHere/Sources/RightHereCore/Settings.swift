import Foundation
import CoreFoundation

/// A terminal app RightHere knows how to open a folder in.
public struct Terminal: Equatable {
    public let bundleIdentifier: String
    public let name: String
    public init(bundleIdentifier: String, name: String) { self.bundleIdentifier = bundleIdentifier; self.name = name }

    public static let fallbackIdentifier = "com.apple.Terminal"
    /// The fixed list of terminals RightHere offers, found by bundle identifier.
    public static let known: [Terminal] = [
        Terminal(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
        Terminal(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm"),
        Terminal(bundleIdentifier: "com.mitchellh.ghostty", name: "Ghostty"),
        Terminal(bundleIdentifier: "dev.warp.Warp-Stable", name: "Warp"),
        Terminal(bundleIdentifier: "net.kovidgoyal.kitty", name: "kitty"),
        Terminal(bundleIdentifier: "com.github.wez.wezterm", name: "WezTerm"),
        Terminal(bundleIdentifier: "org.alacritty", name: "Alacritty")
    ]

    /// The known terminals whose bundle identifier `isInstalled` accepts, in list order.
    public static func available(isInstalled: (String) -> Bool) -> [Terminal] {
        known.filter { isInstalled($0.bundleIdentifier) }
    }

    /// The terminal to open: the saved one if installed, otherwise Terminal.
    public static func resolve(saved: String, available: [Terminal]) -> (identifier: String, fellBack: Bool) {
        if available.contains(where: { $0.bundleIdentifier == saved }) { return (saved, false) }
        return (fallbackIdentifier, saved != fallbackIdentifier)
    }
}

public struct RightHereSettings: Equatable {
    public static let defaultExtensions = ["txt", "md"]
    public static let domain = "com.andrew.righthere"
    public var showsNewFile = true
    public var showsOpenTerminal = true
    public var showsCopyPath = true
    public var newFileExtensions = RightHereSettings.defaultExtensions
    public var terminalBundleIdentifier = Terminal.fallbackIdentifier
    public init() {}
}

public enum SettingsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public enum ExtensionName {
    public static let maximumCount = 8
    public static func isValid(_ value: String) -> Bool {
        (1...10).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
    public static func isValidList(_ list: [String]) -> Bool {
        (1...maximumCount).contains(list.count) && list.allSatisfy(isValid) && Set(list).count == list.count
    }
}

/// A validated settings patch. The whole patch is checked before anything is written.
public struct SettingsPatch {
    public static let booleanKeys: Set<String> = ["showsNewFile", "showsOpenTerminal", "showsCopyPath"]
    public static let writableKeys: Set<String> = booleanKeys.union(["newFileExtensions", "terminalBundleIdentifier", "launchAtLogin"])
    public static let readOnlyKeys: Set<String> = ["schemaVersion", "app", "availableTerminals", "extensionEnabled",
                                                   "loginStatus", "terminalFellBack"]
    /// Values to write. `launchAtLogin` (always false) is accepted and dropped here.
    public let values: [String: Any]

    public init(data: Data, availableTerminals: [Terminal]) throws {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalid("Expected a JSON object smaller than 64 KB.")
        }
        guard Set(object.keys).isSubset(of: Self.writableKeys) else { throw SettingsError.invalid("Unknown or read-only setting.") }
        var cleaned: [String: Any] = [:]
        for (key, value) in object {
            switch key {
            case "launchAtLogin":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw SettingsError.invalid("launchAtLogin must be a Boolean.")
                }
                if number.boolValue { throw SettingsError.invalid("RightHere does not stay running, so it cannot launch at login.") }
            case "newFileExtensions":
                guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
                    throw SettingsError.invalid("newFileExtensions must be an array of strings.")
                }
                let names = list.compactMap { $0 as? String }
                guard ExtensionName.isValidList(names) else {
                    throw SettingsError.invalid("newFileExtensions needs 1 to 8 unique entries of 1 to 10 characters from a-z and 0-9.")
                }
                cleaned[key] = names
            case "terminalBundleIdentifier":
                guard let identifier = value as? String, availableTerminals.contains(where: { $0.bundleIdentifier == identifier }) else {
                    throw SettingsError.invalid("terminalBundleIdentifier must be one of availableTerminals.")
                }
                cleaned[key] = identifier
            default:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw SettingsError.invalid("\(key) must be a Boolean.")
                }
                cleaned[key] = number.boolValue
            }
        }
        values = cleaned
    }
}

/// Reads and writes the settings in one preferences domain. The app writes it; the sandboxed
/// extension reads it through a read-only shared-preference exception for exactly this domain.
public struct SettingsStore {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Anything missing or of the wrong type falls back to its default.
    public var settings: RightHereSettings {
        var value = RightHereSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let object = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(object) == CFBooleanGetTypeID() else { return fallback }
            return object.boolValue
        }
        value.showsNewFile = bool("showsNewFile", true)
        value.showsOpenTerminal = bool("showsOpenTerminal", true)
        value.showsCopyPath = bool("showsCopyPath", true)
        if let list = defaults.array(forKey: "newFileExtensions") as? [String], ExtensionName.isValidList(list) { value.newFileExtensions = list }
        if let id = defaults.object(forKey: "terminalBundleIdentifier") as? String, !id.isEmpty { value.terminalBundleIdentifier = id }
        return value
    }

    public func write(_ patch: SettingsPatch) {
        for (key, value) in patch.values { defaults.set(value, forKey: key) }
    }

    /// The bridge snapshot. `terminalBundleIdentifier` is the terminal that will actually open.
    public func snapshot(availableTerminals: [Terminal], extensionEnabled: Bool) -> [String: Any] {
        let s = settings
        let resolved = Terminal.resolve(saved: s.terminalBundleIdentifier, available: availableTerminals)
        return ["schemaVersion": 1, "app": "rightHere",
                "launchAtLogin": false, "loginStatus": "notApplicable",
                "showsNewFile": s.showsNewFile, "showsOpenTerminal": s.showsOpenTerminal, "showsCopyPath": s.showsCopyPath,
                "newFileExtensions": s.newFileExtensions,
                "terminalBundleIdentifier": resolved.identifier, "terminalFellBack": resolved.fellBack,
                "availableTerminals": availableTerminals.map { ["bundleIdentifier": $0.bundleIdentifier, "name": $0.name] },
                "extensionEnabled": extensionEnabled]
    }
}
