import AppKit
import ApplicationServices
import StayLitCore

/// The one media-key tap. It exists only while a display-key switch is on and
/// Accessibility is granted, and it passes every event through untouched unless the
/// router claims it. Claimed keys are acted on after the callback returns, so the
/// callback does no display I/O.
final class MediaKeyTap {
    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private var wanted = false
    private var gate = MediaKeyGate()
    /// Decides on the main thread, inside the callback; must be cheap.
    var decide: ((MediaKey) -> KeyClaim)?
    var perform: ((KeyClaim) -> Void)?
    var didChange: (() -> Void)?

    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }

    func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        guard wanted, AXIsProcessTrusted() else { return remove() }
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << CGEventMask(MediaKeyEvent.systemDefinedType),
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = (port, source)
        didChange?()
    }

    func remove() {
        guard let installed = tap else { return }
        CGEvent.tapEnable(tap: installed.port, enable: false)
        CFMachPortInvalidate(installed.port)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), installed.source, .commonModes)
        tap = nil
        didChange?()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never leave a disabled tap behind: re-enable it while it is wanted, else remove it.
            if wanted, AXIsProcessTrusted(), let tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
            else { DispatchQueue.main.async { [weak self] in self?.remove() } }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == MediaKeyEvent.systemDefinedType, let system = NSEvent(cgEvent: event), system.type == .systemDefined else {
            return Unmanaged.passUnretained(event)
        }
        let key = MediaKeyEvent(subtype: system.subtype.rawValue, data1: system.data1)
        switch gate.handle(key, wanted: wanted, claim: { decide?($0) ?? .pass }) {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        case .act(let claim):
            DispatchQueue.main.async { [weak self] in self?.perform?(claim) }
            return nil
        }
    }

    deinit { remove() }
}
