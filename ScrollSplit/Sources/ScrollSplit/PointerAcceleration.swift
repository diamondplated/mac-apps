import AppKit
import ScrollSplitCore

/// Turns pointer acceleration off for mice only, through the HID event system client
/// (the approach LinearMouse and similar tools use). When the private interface is
/// missing the feature is unavailable and nothing is touched. The change is not
/// persistent: it is reapplied when a mouse connects and on wake, and each changed device
/// gets its own value back when the feature turns off or ScrollSplit quits.
final class PointerAcceleration {
    static var isAvailable: Bool { HIDEventSystem.isAvailable }

    private static let accelerationKey = "HIDMouseAcceleration"
    private let system = HIDEventSystem()
    private var ledger = AccelerationLedger()
    private(set) var active = false
    private lazy var watcher = HIDDeviceWatcher { [weak self] in self?.apply() }

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

    private func mice() -> [HIDEventSystem.Service] {
        system.services().filter { service in
            let builtIn = (service.property("Built-In") as? NSNumber)?.boolValue ?? false
            return MouseServiceFilter.isMouse(conformsToMouse: service.conforms(page: 0x01, usage: 0x02),
                                              conformsToTouchPad: service.conforms(page: 0x0D, usage: 0x05),
                                              isBuiltIn: builtIn, product: service.property("Product") as? String)
        }
    }

    private func apply() {
        guard active else { return }
        let linear = NSNumber(value: AccelerationLedger.linear)
        for service in mice() {
            let current = (service.property(Self.accelerationKey) as? NSNumber)?.int64Value
            if ledger.linearize(device: service.id, current: current) { service.set(Self.accelerationKey, linear) }
        }
    }

    private func restore() {
        let stored = UserDefaults.standard.object(forKey: "com.apple.mouse.scaling")
        let scaling = (stored as? NSNumber)?.doubleValue ?? (stored as? String).flatMap(Double.init)
        let values = ledger.restorations(fallback: AccelerationLedger.fixedPoint(scaling: scaling))
        guard !values.isEmpty else { return }
        for service in mice() {
            if let value = values[service.id] { service.set(Self.accelerationKey, NSNumber(value: value)) }
        }
    }
}
