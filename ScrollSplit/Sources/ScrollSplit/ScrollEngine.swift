import AppKit
import ApplicationServices
import ScrollSplitCore

final class ScrollEngine {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var transformer = WheelTransformer(settings: ScrollSettings())
    private(set) var settings = ScrollSettings()
    var didChange: ((Bool) -> Void)?
    static let ownMarker: Int64 = 0x535343524F4C4C
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func configure(_ newSettings: ScrollSettings) {
        if settings != newSettings { transformer = WheelTransformer(settings: newSettings) }
        settings = newSettings
        guard settings.enabled, AXIsProcessTrusted(), CGPreflightListenEventAccess() else { stop(); return }
        if tap != nil { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { didChange?(false); return }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        didChange?(active)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        didChange?(false)
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if settings.enabled, AXIsProcessTrusted(), CGPreflightListenEventAccess(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            didChange?(active)
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel { transformer.transform(event) }
        return Unmanaged.passUnretained(event)
    }
}
