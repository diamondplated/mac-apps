import AppKit
import ScrollSplitCore

/// Maps Caps Lock to F18 on every keyboard with a `UserKeyMapping` through the HID event
/// system client. The mapping is not persistent: it is applied when the switch turns on,
/// when a keyboard connects and on wake, and exactly what ScrollSplit added is removed when
/// the switch turns off or ScrollSplit quits. Any mapping already on the keyboard stays,
/// and a Caps Lock mapping of the user's that this one displaced is put back.
///
/// The ledger is also saved, so a crash is cleaned up at the next launch.
final class CapsLockRemap {
    static var isAvailable: Bool { HIDEventSystem.isAvailable }
    private static let mappingKey = "UserKeyMapping"
    private static let ledgerKey = "capsLockRemapLedger"

    private let system = HIDEventSystem()
    private let defaults: UserDefaults
    private var ledger: KeyMappingLedger
    private(set) var active = false
    private lazy var watcher = HIDDeviceWatcher { [weak self] in self?.apply() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(KeyMappingLedger.self, from: $0) } ?? KeyMappingLedger()
        // Left over from a run that ended without turning the mapping off.
        if !ledger.isEmpty { restore() }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        if on {
            guard Self.isAvailable else { return }
            active = true
            apply()
            watcher.start()
        } else {
            active = false
            watcher.stop()
            restore()
        }
    }

    private func keyboards() -> [HIDEventSystem.Service] {
        system.services().filter { $0.conforms(page: 0x01, usage: 0x06) }
    }

    private func apply() {
        guard active else { return }
        for keyboard in keyboards() {
            // A mapping this code cannot read is never rewritten.
            guard let current = KeyMappingEntry.parse(keyboard.property(Self.mappingKey)),
                  let mapping = ledger.adding(device: keyboard.id, current: current) else { continue }
            keyboard.set(Self.mappingKey, KeyMappingEntry.property(mapping) as NSArray)
        }
        save()
    }

    private func restore() {
        guard !ledger.isEmpty else { return }
        for keyboard in keyboards() {
            guard let current = KeyMappingEntry.parse(keyboard.property(Self.mappingKey)),
                  let mapping = ledger.removing(device: keyboard.id, current: current) else { continue }
            keyboard.set(Self.mappingKey, KeyMappingEntry.property(mapping) as NSArray)
        }
        ledger.clear()
        save()
    }

    private func save() {
        if ledger.isEmpty { defaults.removeObject(forKey: Self.ledgerKey) }
        else if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}
