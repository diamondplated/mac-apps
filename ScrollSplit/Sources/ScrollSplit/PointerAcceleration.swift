import AppKit
import IOKit
import ScrollSplitCore

/// Turns pointer acceleration off for mice only, through the HID event system client
/// (the approach LinearMouse and similar tools use). The interface is private, so every
/// symbol is looked up at run time; when one is missing the feature is unavailable and
/// nothing is touched. The change is not persistent: it is reapplied when a mouse
/// connects and on wake, and each changed device gets its own value back when the
/// feature turns off or ScrollSplit quits.
final class PointerAcceleration {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    // These two return `Boolean`, a single byte: declaring a wider type would read garbage.
    private typealias ConformsTo = @convention(c) (AnyObject, UInt32, UInt32) -> UInt8
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias SetProperty = @convention(c) (AnyObject, CFString, AnyObject) -> UInt8
    private typealias GetRegistryID = @convention(c) (AnyObject) -> Unmanaged<AnyObject>?

    private struct Symbols {
        let createClient: CreateClient
        let copyServices: CopyServices
        let conformsTo: ConformsTo
        let copyProperty: CopyProperty
        let setProperty: SetProperty
        let registryID: GetRegistryID
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create = load("IOHIDEventSystemClientCreateSimpleClient", CreateClient.self),
              let services = load("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let conforms = load("IOHIDServiceClientConformsTo", ConformsTo.self),
              let copy = load("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let set = load("IOHIDServiceClientSetProperty", SetProperty.self),
              let registry = load("IOHIDServiceClientGetRegistryID", GetRegistryID.self) else { return nil }
        return Symbols(createClient: create, copyServices: services, conformsTo: conforms,
                       copyProperty: copy, setProperty: set, registryID: registry)
    }()

    /// Symbol lookup only: creates no client and opens no consent prompt.
    static var isAvailable: Bool { symbols != nil }

    private static let accelerationKey = "HIDMouseAcceleration" as CFString
    private var client: AnyObject?
    private var ledger = AccelerationLedger()
    private(set) var active = false
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var pendingApply: DispatchWorkItem?

    func setActive(_ on: Bool) {
        guard on != active else { return }
        if on {
            guard Self.symbols != nil else { return }
            active = true
            apply()
            startWatching()
        } else {
            active = false
            stopWatching()
            restore()
        }
    }

    private func mice() -> [(id: UInt64, service: AnyObject)] {
        guard let symbols = Self.symbols else { return [] }
        if client == nil { client = symbols.createClient(kCFAllocatorDefault)?.takeRetainedValue() }
        guard let client, let array = symbols.copyServices(client)?.takeRetainedValue() else { return [] }
        return (array as NSArray as [AnyObject]).compactMap { service in
            let builtIn = (symbols.copyProperty(service, "Built-In" as CFString)?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
            let product = symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            guard MouseServiceFilter.isMouse(conformsToMouse: symbols.conformsTo(service, 0x01, 0x02) != 0,
                                             conformsToTouchPad: symbols.conformsTo(service, 0x0D, 0x05) != 0,
                                             isBuiltIn: builtIn, product: product),
                  let id = (symbols.registryID(service)?.takeUnretainedValue() as? NSNumber)?.uint64Value else { return nil }
            return (id, service)
        }
    }

    private func apply() {
        guard active, let symbols = Self.symbols else { return }
        let linear = NSNumber(value: AccelerationLedger.linear)
        for (id, service) in mice() {
            let current = (symbols.copyProperty(service, Self.accelerationKey)?.takeRetainedValue() as? NSNumber)?.int64Value
            if ledger.linearize(device: id, current: current) { _ = symbols.setProperty(service, Self.accelerationKey, linear) }
        }
    }

    private func restore() {
        guard let symbols = Self.symbols else { return }
        let stored = UserDefaults.standard.object(forKey: "com.apple.mouse.scaling")
        let scaling = (stored as? NSNumber)?.doubleValue ?? (stored as? String).flatMap(Double.init)
        let values = ledger.restorations(fallback: AccelerationLedger.fixedPoint(scaling: scaling))
        guard !values.isEmpty else { return }
        for (id, service) in mice() {
            if let value = values[id] { _ = symbols.setProperty(service, Self.accelerationKey, NSNumber(value: value)) }
        }
    }

    /// A new HID service appears a moment after the device; settle, then reapply once.
    private func scheduleApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
    }

    private func startWatching() {
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                PointerAcceleration.drain(iterator)
                guard let refcon else { return }
                Unmanaged<PointerAcceleration>.fromOpaque(refcon).takeUnretainedValue().scheduleApply()
            }
            if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                                callback, Unmanaged.passUnretained(self).toOpaque(), &iterator) == KERN_SUCCESS {
                Self.drain(iterator) // arms the notification
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleApply()
        }
    }

    private func stopWatching() {
        pendingApply?.cancel(); pendingApply = nil
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}
