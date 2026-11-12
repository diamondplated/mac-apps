import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import StayLitCore

/// The real IOKit power-management assertions. Only the running app creates one.
final class IOKitPowerService: PowerService {
    func takeAssertion(_ kind: AssertionKind, reason: String) -> UInt32? {
        let type = kind == .display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            NSLog("StayLit could not take a power assertion: \(result)")
            return nil
        }
        return id
    }

    func releaseAssertion(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// Reads the power source and reports changes on the main run loop.
final class PowerSourceMonitor {
    private var source: CFRunLoopSource?
    var onChange: (() -> Void)?

    static var current: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .mains }
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return PowerSource(onBattery: onBattery, percent: nil) }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return PowerSource(onBattery: onBattery, percent: Int((Double(capacity) * 100 / Double(maximum)).rounded()))
        }
        return PowerSource(onBattery: onBattery, percent: nil)
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    deinit { stop() }
}
