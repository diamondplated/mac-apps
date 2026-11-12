import AppKit
import IOKit
import QuartzCore
import StayLitCore

/// A display's DDC/CI channel. On Apple silicon that is the private IOAVService
/// interface; every symbol is looked up at run time and a missing one means "not
/// supported". Intel Macs are not supported in this version. Used only off the main thread.
final class DDCChannel {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

    private static let functions: (create: Create, read: Read, write: Write)? = {
        #if arch(arm64)
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return (unsafeBitCast(create, to: Create.self), unsafeBitCast(read, to: Read.self), unsafeBitCast(write, to: Write.self))
        #else
        return nil
        #endif
    }()

    static var isAvailable: Bool { functions != nil }

    private let service: CFTypeRef
    private init(service: CFTypeRef) { self.service = service }

    /// External display channels in registry order, each with the EDID attributes of the
    /// framebuffer it belongs to. Reads the I/O registry only; nothing is sent to a display.
    static func discover() -> [(channel: DDCChannel, attributes: ChannelAttributes?)] {
        guard let functions else { return [] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(DDCChannel, ChannelAttributes?)] = []
        var framebuffer: ChannelAttributes?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            var buffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { continue }
            let name = String(cString: buffer)
            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                framebuffer = attributes(of: entry)
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                guard location == "External", let service = functions.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append((DDCChannel(service: service), framebuffer))
                framebuffer = nil
            }
        }
        return found
    }

    private static func attributes(of entry: io_registry_entry_t) -> ChannelAttributes? {
        guard let display = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let product = display["ProductAttributes"] as? [String: Any],
              let vendor = product["LegacyManufacturerID"] as? Int, let model = product["ProductID"] as? Int else { return nil }
        return ChannelAttributes(vendor: UInt32(truncatingIfNeeded: vendor), product: UInt32(truncatingIfNeeded: model),
                                 serial: UInt32(truncatingIfNeeded: product["SerialNumber"] as? Int ?? 0))
    }

    /// Reads a VCP value. A display that does not answer gives nil.
    func read(_ code: DDC.Code) -> DDC.Value? {
        guard let functions = Self.functions else { return nil }
        var request = DDC.readRequest(code.rawValue)
        for _ in 0..<3 {
            var wrote = false
            for _ in 0..<2 {
                wrote = functions.write(service, UInt32(DDC.chipAddress), UInt32(DDC.hostAddress), &request, UInt32(request.count)) == kIOReturnSuccess || wrote
                usleep(10_000)
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: DDC.replyLength)
            if wrote, functions.read(service, UInt32(DDC.chipAddress), UInt32(DDC.hostAddress), &reply, UInt32(reply.count)) == kIOReturnSuccess,
               let value = DDC.parseReply(reply, expecting: code.rawValue) {
                return value
            }
            usleep(20_000)
        }
        return nil
    }

    /// Sets a VCP value. Returns false if the channel refused the write.
    @discardableResult
    func write(_ code: DDC.Code, value: Int) -> Bool {
        guard let functions = Self.functions else { return false }
        var packet = DDC.writeRequest(code.rawValue, value: UInt16(clamping: value))
        var wrote = false
        for _ in 0..<2 {
            wrote = functions.write(service, UInt32(DDC.chipAddress), UInt32(DDC.hostAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess || wrote
            usleep(10_000)
        }
        return wrote
    }
}

/// Connected displays, their DDC channels and cached values. Values are read once when
/// displays connect, and writes are rate-limited per display and control. Main thread only.
final class DisplayController {
    private(set) var displays: [DisplayInfo] = []
    private var channels: [UInt32: DDCChannel] = [:]
    private var volumes: [UInt32: DisplayVolume] = [:]
    private var limiters: [String: WriteLimiter] = [:]
    /// Displays whose values have been read. Until then, "controllable" means a channel was found.
    private var probed = Set<UInt32>()
    private let queue = DispatchQueue(label: "StayLit.ddc", qos: .userInitiated)
    var didChange: (() -> Void)?

    var externalDisplays: [[String: Any]] {
        displays.filter(\.isExternal).map { display in
            let controllable = probed.contains(display.id) ? display.controllable : !display.systemControlsBrightness && channels[display.id] != nil
            return ["name": display.name, "controllable": controllable]
        }
    }

    /// True when some connected display with a channel has not been read yet.
    var needsProbe: Bool { channels.keys.contains { !probed.contains($0) } }

    func display(_ id: UInt32) -> DisplayInfo? { displays.first { $0.id == id } }

    /// The display under the pointer. Cheap enough for the event tap.
    func pointerDisplay() -> DisplayInfo? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), let id = screen.displayID else { return nil }
        return display(id)
    }

    /// The connected screens with their EDID attributes. Main thread; cheap.
    static func screens() -> [(display: DisplayInfo, attributes: ChannelAttributes)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return (DisplayInfo(id: id, name: screen.localizedName, isBuiltin: CGDisplayIsBuiltin(id) != 0, vendor: CGDisplayVendorNumber(id)),
                    ChannelAttributes(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id)))
        }
    }

    /// Pairs registry channels with screens. Reads the I/O registry only; nothing is sent to a display.
    static func channels(for screens: [(display: DisplayInfo, attributes: ChannelAttributes)]) -> [UInt32: DDCChannel] {
        let candidates = screens.filter { !$0.display.systemControlsBrightness }
        let found = DDCChannel.discover()
        let pairs = ChannelMatcher.match(channels: found.map(\.attributes), displays: candidates.map { ($0.display.id, $0.attributes) })
        var channels: [UInt32: DDCChannel] = [:]
        for (index, id) in pairs { channels[id] = found[index].channel }
        return channels
    }

    /// For the bridge when the app is not running: a display counts as controllable when
    /// it has a DDC channel, since only the running app reads from displays.
    static func staticExternalDisplays() -> [[String: Any]] {
        let listed = screens()
        let channels = channels(for: listed)
        return listed.map(\.display).filter(\.isExternal).map { ["name": $0.name, "controllable": !$0.systemControlsBrightness && channels[$0.id] != nil] }
    }

    private var refreshing = false
    private var pendingProbe: Bool?

    /// Re-lists displays. The registry walk and any reads run on the DDC queue, never on the
    /// main thread where the key tap runs. With `probe`, each channel not read yet has its
    /// brightness and volume read once; displays already read keep their cached values.
    /// A request made while one is running is folded into a single follow-up run.
    func refresh(probe: Bool) {
        if refreshing { pendingProbe = (pendingProbe ?? false) || probe; return }
        refreshing = true
        let listed = Self.screens()
        let alreadyRead = probed
        queue.async { [weak self] in
            let found = Self.channels(for: listed)
            var values: [UInt32: (DDC.Value?, DDC.Value?)] = [:]
            if probe { for (id, channel) in found where !alreadyRead.contains(id) { values[id] = (channel.read(.brightness), channel.read(.volume)) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.publish(listed.map(\.display), found, values)
                self.refreshing = false
                if let next = self.pendingProbe { self.pendingProbe = nil; self.refresh(probe: next) }
            }
        }
    }

    private func publish(_ listed: [DisplayInfo], _ found: [UInt32: DDCChannel], _ values: [UInt32: (DDC.Value?, DDC.Value?)]) {
        let previous = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        probed = probed.filter { found[$0] != nil }
        volumes = volumes.filter { probed.contains($0.key) }
        displays = listed.map { display in
            var display = display
            if let (brightness, volume) = values[display.id] {
                display.brightness = brightness
                display.volume = volume
                probed.insert(display.id)
                volumes[display.id] = volume.map { DisplayVolume(level: $0.current, maximum: $0.maximum) }
            } else if probed.contains(display.id), let known = previous[display.id] {
                display.brightness = known.brightness
                display.volume = known.volume
            }
            return display
        }
        channels = found
        didChange?()
    }

    func adjustBrightness(_ id: UInt32, up: Bool) -> IndicatorModel? {
        guard let index = displays.firstIndex(where: { $0.id == id }), let value = displays[index].brightness else { return nil }
        let next = Steps.next(current: value.current, maximum: value.maximum, up: up)
        displays[index].brightness?.current = next
        send(.brightness, next, to: id)
        return IndicatorModel(kind: .brightness, level: Steps.fraction(current: next, maximum: value.maximum), displayName: displays[index].name)
    }

    func adjustVolume(_ id: UInt32, up: Bool?) -> IndicatorModel? {
        guard let display = display(id), var volume = volumes[id] else { return nil }
        let next = up.map { volume.step(up: $0) } ?? volume.toggleMute()
        volumes[id] = volume
        send(.volume, next, to: id)
        return IndicatorModel(kind: volume.isMuted ? .muted : .volume, level: Steps.fraction(current: volume.level, maximum: volume.maximum), displayName: display.name)
    }

    private func send(_ code: DDC.Code, _ value: Int, to id: UInt32) {
        guard let channel = channels[id] else { return }
        let key = "\(id)-\(code.rawValue)"
        var limiter = limiters[key] ?? WriteLimiter()
        let decision = limiter.request(value, at: CACurrentMediaTime())
        limiters[key] = limiter
        switch decision {
        case .write(let value):
            queue.async { channel.write(code, value: value) }
        case .schedule(let time):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - CACurrentMediaTime())) { [weak self] in
                guard let self, var limiter = self.limiters[key], let value = limiter.fire(at: CACurrentMediaTime()) else { return }
                self.limiters[key] = limiter
                self.queue.async { channel.write(code, value: value) }
            }
        case .coalesced:
            break
        }
    }
}

extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}
