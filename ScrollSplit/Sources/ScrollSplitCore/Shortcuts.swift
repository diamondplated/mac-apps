import Foundation
import CoreFoundation

/// The two global shortcuts, in the order the settings snapshot lists them. New commands
/// are only ever appended and start unassigned.
public enum ShortcutCommand: String, CaseIterable, Codable {
    case pastePlainText, toggleMicrophoneMute

    public var title: String {
        switch self {
        case .pastePlainText: return "Paste as Plain Text"
        case .toggleMicrophoneMute: return "Mute or Unmute Microphone"
        }
    }
}

/// A key and its Carbon modifiers, in exactly the shape ScreenWren and the Mac Tools
/// recorder use: `{keyCode, carbonModifiers, keyEquivalent, keyLabel}`.
public struct KeyShortcut: Codable, Equatable, Hashable {
    // Carbon's cmdKey, shiftKey, optionKey and controlKey.
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000
    public static let allowedModifiers = command | shift | option | control

    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let keyEquivalent: String
    public let keyLabel: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, keyEquivalent: String, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyEquivalent = keyEquivalent
        self.keyLabel = keyLabel
    }

    /// The physical key and modifiers; the strings are only labels.
    public struct Combination: Hashable { public let keyCode: UInt32; public let carbonModifiers: UInt32 }
    public var combination: Combination { Combination(keyCode: keyCode, carbonModifiers: carbonModifiers) }

    /// Shift alone is not enough: it would steal ordinary typing.
    public var hasRequiredModifier: Bool { carbonModifiers & (Self.command | Self.control | Self.option) != 0 }

    public var isValid: Bool {
        keyCode <= 127 && hasRequiredModifier && carbonModifiers & ~Self.allowedModifiers == 0
            && !keyEquivalent.isEmpty && keyEquivalent.count <= 2
            && !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyLabel.count <= 32
    }

    /// The menu-style name, such as ⌃⌥V.
    public var displayName: String {
        var result = ""
        if carbonModifiers & Self.control != 0 { result += "⌃" }
        if carbonModifiers & Self.option != 0 { result += "⌥" }
        if carbonModifiers & Self.shift != 0 { result += "⇧" }
        if carbonModifiers & Self.command != 0 { result += "⌘" }
        return result + keyLabel
    }
}

/// Shortcut assignments in ScrollSplit's preference domain. An absent value is unassigned,
/// which is also every command's default.
public struct ShortcutStore {
    public static let prefix = "shortcuts.v1."
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func shortcut(for command: ShortcutCommand) -> KeyShortcut? {
        guard let data = defaults.data(forKey: Self.prefix + command.rawValue),
              let value = try? JSONDecoder().decode(KeyShortcut.self, from: data), value.isValid else { return nil }
        return value
    }

    public func set(_ shortcut: KeyShortcut?, for command: ShortcutCommand) {
        let key = Self.prefix + command.rawValue
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    public func reset() { for command in ShortcutCommand.allCases { set(nil, for: command) } }

    public var all: [ShortcutCommand: KeyShortcut] {
        var result: [ShortcutCommand: KeyShortcut] = [:]
        for command in ShortcutCommand.allCases { result[command] = shortcut(for: command) }
        return result
    }

    /// The snapshot's `shortcuts` array: every command in order, null when unassigned.
    public var snapshot: [[String: Any]] {
        ShortcutCommand.allCases.map { command in
            let value: Any = shortcut(for: command).map {
                ["keyCode": $0.keyCode, "carbonModifiers": $0.carbonModifiers, "keyEquivalent": $0.keyEquivalent, "keyLabel": $0.keyLabel] as [String: Any]
            } ?? NSNull()
            return ["command": command.rawValue, "title": command.title, "shortcut": value]
        }
    }
}

/// The `shortcuts` / `resetShortcuts` part of a settings patch, validated as a whole
/// against the current assignments before anything is written.
public struct ShortcutPatch: Equatable {
    public let changes: [ShortcutCommand: KeyShortcut?]
    public let reset: Bool

    public init(shortcuts: Any?, resetShortcuts: Any?, current: [ShortcutCommand: KeyShortcut]) throws {
        var reset = false
        if let resetShortcuts {
            guard let number = resetShortcuts as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw SettingsError.invalid("resetShortcuts must be a Boolean.")
            }
            reset = number.boolValue
        }
        var changes: [ShortcutCommand: KeyShortcut?] = [:]
        if let shortcuts {
            guard !reset else { throw SettingsError.invalid("Do not combine resetShortcuts and shortcuts.") }
            guard let entries = shortcuts as? [Any] else { throw SettingsError.invalid("shortcuts must be an array.") }
            for entry in entries {
                guard let entry = entry as? [String: Any], Set(entry.keys).isSubset(of: ["command", "title", "shortcut"]),
                      let name = entry["command"] as? String, entry.keys.contains("shortcut") else {
                    throw SettingsError.invalid("Each shortcut needs a command and a shortcut.")
                }
                guard let command = ShortcutCommand(rawValue: name) else { throw SettingsError.invalid("Unknown shortcut command \(name).") }
                guard changes[command] == nil else { throw SettingsError.invalid("Include each shortcut command at most once.") }
                if let title = entry["title"], !(title is String) { throw SettingsError.invalid("Invalid title for \(command.title).") }
                changes[command] = .some(try Self.shortcut(entry["shortcut"], for: command))
            }
            var merged: [ShortcutCommand: KeyShortcut] = current
            for (command, value) in changes { merged[command] = value }
            let combinations = merged.values.map(\.combination)
            guard Set(combinations).count == combinations.count else {
                throw SettingsError.invalid("Shortcut key combinations must be unique.")
            }
        }
        self.changes = changes
        self.reset = reset
    }

    private static func shortcut(_ value: Any?, for command: ShortcutCommand) throws -> KeyShortcut? {
        if value is NSNull { return nil }
        let invalid = SettingsError.invalid("Invalid shortcut for \(command.title).")
        let keys: Set<String> = ["keyCode", "carbonModifiers", "keyEquivalent", "keyLabel"]
        guard let object = value as? [String: Any], Set(object.keys) == keys,
              let keyCode = integer(object["keyCode"]), let modifiers = integer(object["carbonModifiers"]),
              let equivalent = object["keyEquivalent"] as? String, let label = object["keyLabel"] as? String else { throw invalid }
        let shortcut = KeyShortcut(keyCode: keyCode, carbonModifiers: modifiers, keyEquivalent: equivalent, keyLabel: label)
        guard shortcut.isValid else { throw invalid }
        return shortcut
    }

    /// A whole, non-negative JSON number that is not a Boolean.
    private static func integer(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(UInt32.max), double.rounded() == double else { return nil }
        return UInt32(double)
    }

    public var isEmpty: Bool { changes.isEmpty && !reset }

    public func apply(to store: ShortcutStore) {
        if reset { store.reset() }
        for (command, value) in changes { store.set(value, for: command) }
    }
}
