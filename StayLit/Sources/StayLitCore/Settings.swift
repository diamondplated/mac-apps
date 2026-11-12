import Foundation
import CoreFoundation

public struct StayLitSettings: Equatable {
    public var keepAwake = false
    public var keepAwakeApps: [String] = []
    public var keepsDisplayAwake = false
    public var brightnessKeysControlDisplays = false
    public var volumeKeysControlDisplays = false
    public init() {}

    /// The one media-key tap exists only while one of these is on.
    public var wantsKeyTap: Bool { brightnessKeysControlDisplays || volumeKeysControlDisplays }
}

/// A bundle identifier as the bridge accepts it: 1–255 characters of letters,
/// digits, dots, hyphens and underscores.
public enum BundleIdentifier {
    public static let maximumApps = 50
    public static func isValid(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }
    }

    /// Keeps the first occurrence of each identifier, in order.
    public static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct SettingsPatch {
    public static let booleanKeys: Set<String> = ["keepAwake", "keepsDisplayAwake", "brightnessKeysControlDisplays",
                                                  "volumeKeysControlDisplays", "launchAtLogin"]
    public static let listKeys: Set<String> = ["keepAwakeApps"]
    public static var writableKeys: Set<String> { booleanKeys.union(listKeys) }
    public static let readOnlyKeys: Set<String> = ["schemaVersion", "app", "loginStatus", "awakeReason", "externalDisplays",
                                                   "permissions", "permissionsSource"]
    public let values: [String: Any]

    /// Validates the whole patch before anything is written.
    public init(data: Data) throws {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalid("Expected a JSON object smaller than 64 KB.")
        }
        guard Set(object.keys).isSubset(of: Self.writableKeys) else { throw SettingsError.invalid("Unknown or read-only setting.") }
        var cleaned: [String: Any] = [:]
        for (key, value) in object {
            if Self.booleanKeys.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw SettingsError.invalid("\(key) must be a Boolean.")
                }
                cleaned[key] = number.boolValue
            } else {
                guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
                    throw SettingsError.invalid("keepAwakeApps must be an array of bundle identifiers.")
                }
                let identifiers = BundleIdentifier.deduplicated(list.compactMap { $0 as? String })
                guard identifiers.allSatisfy(BundleIdentifier.isValid) else { throw SettingsError.invalid("keepAwakeApps holds an invalid bundle identifier.") }
                guard identifiers.count <= BundleIdentifier.maximumApps else { throw SettingsError.invalid("keepAwakeApps holds more than 50 apps.") }
                cleaned[key] = identifiers
            }
        }
        values = cleaned
    }
}

public enum SettingsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// Reads and writes the behaviour settings in one preferences domain. Launch at
/// login is not stored here; the app's bridge handles it.
public struct SettingsStore {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var settings: StayLitSettings {
        var value = StayLitSettings()
        value.keepAwake = defaults.bool(forKey: "keepAwake")
        let stored = (defaults.array(forKey: "keepAwakeApps") ?? []).compactMap { $0 as? String }.filter(BundleIdentifier.isValid)
        value.keepAwakeApps = Array(BundleIdentifier.deduplicated(stored).prefix(BundleIdentifier.maximumApps))
        value.keepsDisplayAwake = defaults.bool(forKey: "keepsDisplayAwake")
        value.brightnessKeysControlDisplays = defaults.bool(forKey: "brightnessKeysControlDisplays")
        value.volumeKeysControlDisplays = defaults.bool(forKey: "volumeKeysControlDisplays")
        return value
    }

    public func write(_ patch: SettingsPatch) {
        for (key, value) in patch.values where key != "launchAtLogin" { defaults.set(value, forKey: key) }
    }

    /// The behaviour half of the bridge snapshot.
    public func snapshotValues() -> [String: Any] {
        let s = settings
        return ["keepAwake": s.keepAwake, "keepAwakeApps": s.keepAwakeApps, "keepsDisplayAwake": s.keepsDisplayAwake,
                "brightnessKeysControlDisplays": s.brightnessKeysControlDisplays, "volumeKeysControlDisplays": s.volumeKeysControlDisplays]
    }
}

/// Decides whether to show the setup alert at launch. The offer is made once ever:
/// after the first launch the caller records that it happened, whatever the answer.
/// StayLit only needs setup when a display-key switch is on without Accessibility.
public enum SetupOffer {
    public static func shouldOffer(alreadyOffered: Bool, launchedAsLoginItem: Bool, needsAccess: Bool) -> Bool {
        !alreadyOffered && !launchedAsLoginItem && needsAccess
    }
}
