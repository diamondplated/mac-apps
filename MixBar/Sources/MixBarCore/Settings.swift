import Foundation
import CoreFoundation

/// One app's volume, mute and output, remembered by bundle identifier.
public struct AppVolume: Equatable {
    public static let range: ClosedRange<Double> = 0...2
    public var bundleIdentifier: String
    public var name: String
    /// 0...2; 1 is the app's own level.
    public var volume: Double
    public var muted: Bool
    /// nil follows the system default output.
    public var outputDeviceUID: String?

    public init(bundleIdentifier: String, name: String, volume: Double = 1, muted: Bool = false, outputDeviceUID: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.volume = min(max(volume, Self.range.lowerBound), Self.range.upperBound)
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
    }

    /// 100 percent, unmuted, System Default: MixBar leaves the app alone.
    public var isNeutral: Bool { volume == 1 && !muted && outputDeviceUID == nil }

    /// The gain the render path applies.
    public var gain: Float { muted ? 0 : Float(volume) }

    public var dictionary: [String: Any] {
        ["bundleIdentifier": bundleIdentifier, "name": name, "volume": volume, "muted": muted,
         "outputDeviceUID": outputDeviceUID as Any? ?? NSNull()]
    }

    /// A stored entry, or nil when it is not one MixBar would have written.
    public init?(storedDictionary value: Any) {
        guard let entry = value as? [String: Any], let identifier = entry["bundleIdentifier"] as? String, BundleIdentifier.isValid(identifier),
              let volume = (entry["volume"] as? NSNumber).flatMap(JSONValue.number), AppVolume.range.contains(volume),
              let muted = (entry["muted"] as? NSNumber).flatMap(JSONValue.boolean) else { return nil }
        let output = entry["outputDeviceUID"] as? String
        guard output.map(DeviceUID.isValid) ?? true else { return nil }
        self.init(bundleIdentifier: identifier, name: entry["name"] as? String ?? identifier, volume: volume, muted: muted, outputDeviceUID: output)
    }
}

public struct MixBarSettings: Equatable {
    public var remembersVolumes = true
    public var appVolumes: [AppVolume] = []
    public init() {}

    public func saved(_ bundleIdentifier: String) -> AppVolume? { appVolumes.first { $0.bundleIdentifier == bundleIdentifier } }
}

/// A bundle identifier as the bridge accepts it: 1–255 characters of letters,
/// digits, dots, hyphens and underscores.
public enum BundleIdentifier {
    public static let maximumApps = 100
    public static func isValid(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }
    }
}

/// An output device UID as Core Audio reports it: any non-empty string up to 512
/// bytes without control characters.
public enum DeviceUID {
    public static func isValid(_ value: String) -> Bool {
        (1...512).contains(value.utf8.count) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum JSONValue {
    static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    static func boolean(_ number: NSNumber) -> Bool? { isBoolean(number) ? number.boolValue : nil }
    static func number(_ number: NSNumber) -> Double? {
        guard !isBoolean(number) else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

public struct SettingsPatch {
    public static let booleanKeys: Set<String> = ["remembersVolumes", "launchAtLogin"]
    public static let listKeys: Set<String> = ["appVolumes"]
    public static var writableKeys: Set<String> { booleanKeys.union(listKeys) }
    public static let readOnlyKeys: Set<String> = ["schemaVersion", "app", "loginStatus", "audioControlAvailable", "audioCaptureStatus"]
    static let entryKeys: Set<String> = ["bundleIdentifier", "name", "volume", "muted", "outputDeviceUID"]
    public let values: [String: Any]

    /// Validates the whole patch before anything is written.
    public init(data: Data) throws {
        guard data.count <= 262_144, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalid("Expected a JSON object smaller than 256 KB.")
        }
        guard Set(object.keys).isSubset(of: Self.writableKeys) else { throw SettingsError.invalid("Unknown or read-only setting.") }
        var cleaned: [String: Any] = [:]
        for (key, value) in object {
            if Self.booleanKeys.contains(key) {
                guard let number = value as? NSNumber, let flag = JSONValue.boolean(number) else { throw SettingsError.invalid("\(key) must be a Boolean.") }
                cleaned[key] = flag
            } else {
                cleaned[key] = try Self.appVolumes(value)
            }
        }
        values = cleaned
    }

    /// `name` is accepted and ignored; the store keeps its own.
    static func appVolumes(_ value: Any) throws -> [AppVolume] {
        guard let list = value as? [Any] else { throw SettingsError.invalid("appVolumes must be an array.") }
        guard list.count <= BundleIdentifier.maximumApps else { throw SettingsError.invalid("appVolumes holds more than 100 apps.") }
        var seen = Set<String>()
        return try list.map { item in
            guard let entry = item as? [String: Any] else { throw SettingsError.invalid("Each appVolumes entry must be an object.") }
            guard Set(entry.keys).isSubset(of: entryKeys) else { throw SettingsError.invalid("An appVolumes entry has an unknown key.") }
            guard let identifier = entry["bundleIdentifier"] as? String, BundleIdentifier.isValid(identifier) else {
                throw SettingsError.invalid("An appVolumes entry has an invalid bundleIdentifier.")
            }
            guard seen.insert(identifier).inserted else { throw SettingsError.invalid("appVolumes lists \(identifier) twice.") }
            guard let volume = (entry["volume"] as? NSNumber).flatMap(JSONValue.number), AppVolume.range.contains(volume) else {
                throw SettingsError.invalid("volume for \(identifier) must be a number from 0 to 2.")
            }
            guard let muted = (entry["muted"] as? NSNumber).flatMap(JSONValue.boolean) else {
                throw SettingsError.invalid("muted for \(identifier) must be a Boolean.")
            }
            var output: String?
            switch entry["outputDeviceUID"] {
            case nil, is NSNull: output = nil
            case let uid as String where DeviceUID.isValid(uid): output = uid
            default: throw SettingsError.invalid("outputDeviceUID for \(identifier) must be a device UID or null.")
            }
            return AppVolume(bundleIdentifier: identifier, name: identifier, volume: volume, muted: muted, outputDeviceUID: output)
        }
    }

    /// The patch that replaces the saved list, as the mixer writes it.
    public static func data(appVolumes: [AppVolume]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["appVolumes": appVolumes.map(\.dictionary)])) ?? Data("{}".utf8)
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

    public var settings: MixBarSettings {
        var value = MixBarSettings()
        value.remembersVolumes = defaults.object(forKey: "remembersVolumes") as? Bool ?? true
        var seen = Set<String>()
        value.appVolumes = Array((defaults.array(forKey: "appVolumes") ?? []).compactMap(AppVolume.init(storedDictionary:))
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .prefix(BundleIdentifier.maximumApps))
        return value
    }

    /// `nameFor` names an app the store has not seen before; a known app keeps its stored name.
    public func write(_ patch: SettingsPatch, nameFor: (String) -> String? = { _ in nil }) {
        if let remembers = patch.values["remembersVolumes"] as? Bool { defaults.set(remembers, forKey: "remembersVolumes") }
        if let list = patch.values["appVolumes"] as? [AppVolume] {
            let known = settings.appVolumes
            let named = list.map { entry -> AppVolume in
                var entry = entry
                entry.name = known.first { $0.bundleIdentifier == entry.bundleIdentifier }?.name ?? nameFor(entry.bundleIdentifier) ?? entry.bundleIdentifier
                return entry
            }
            defaults.set(named.map(\.dictionary).map { $0.filter { !($0.value is NSNull) } }, forKey: "appVolumes")
        }
    }

    /// The behaviour half of the bridge snapshot.
    public func snapshotValues() -> [String: Any] {
        let s = settings
        return ["remembersVolumes": s.remembersVolumes, "appVolumes": s.appVolumes.map(\.dictionary)]
    }
}

/// Decides whether to show the setup alert at launch. The offer is made once ever:
/// after the first launch the caller records that it happened, whatever the answer.
/// MixBar only needs setup when audio capture was refused while an app has a setting.
public enum SetupOffer {
    public static func shouldOffer(alreadyOffered: Bool, launchedAsLoginItem: Bool, needsAccess: Bool) -> Bool {
        !alreadyOffered && !launchedAsLoginItem && needsAccess
    }
}
