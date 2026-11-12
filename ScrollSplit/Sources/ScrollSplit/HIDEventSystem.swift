import AppKit
import IOKit

/// The private HID event system client that pointer acceleration and the Caps Lock
/// mapping both use. Every symbol is looked up at run time; when one is missing both
/// features are unavailable and nothing is touched.
final class HIDEventSystem {
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

    /// One HID service, with the calls the features make on it.
    struct Service {
        let id: UInt64
        fileprivate let object: AnyObject
        func conforms(page: UInt32, usage: UInt32) -> Bool { HIDEventSystem.symbols.map { $0.conformsTo(object, page, usage) != 0 } ?? false }
        func property(_ key: String) -> AnyObject? { HIDEventSystem.symbols?.copyProperty(object, key as CFString)?.takeRetainedValue() }
        @discardableResult func set(_ key: String, _ value: AnyObject) -> Bool {
            HIDEventSystem.symbols.map { $0.setProperty(object, key as CFString, value) != 0 } ?? false
        }
    }

    private var client: AnyObject?

    /// Every HID service the client sees. Creates the client on first use.
    func services() -> [Service] {
        guard let symbols = Self.symbols else { return [] }
        if client == nil { client = symbols.createClient(kCFAllocatorDefault)?.takeRetainedValue() }
        guard let client, let array = symbols.copyServices(client)?.takeRetainedValue() else { return [] }
        return (array as NSArray as [AnyObject]).compactMap { object in
            guard let id = (symbols.registryID(object)?.takeUnretainedValue() as? NSNumber)?.uint64Value else { return nil }
            return Service(id: id, object: object)
        }
    }
}

/// Calls `onChange` (settled by a second) when a HID device appears and on wake, while started.
final class HIDDeviceWatcher {
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }
    deinit { stop() }

    /// A new HID service appears a moment after the device; settle, then call once.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
    }

    func start() {
        guard notifyPort == nil, wakeObserver == nil else { return }
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                HIDDeviceWatcher.drain(iterator)
                guard let refcon else { return }
                Unmanaged<HIDDeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().schedule()
            }
            if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                                callback, Unmanaged.passUnretained(self).toOpaque(), &iterator) == KERN_SUCCESS {
                Self.drain(iterator) // arms the notification
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule()
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}
