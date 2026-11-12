import AppKit
import ApplicationServices
import QuartzCore
import ScrollSplitCore

/// Posts one key press (down and up), marked as ScrollSplit's own so its taps pass it.
/// With a pid it goes to that process only; otherwise it enters the session like a real key.
func postKeyPress(_ keyCode: CGKeyCode, character: String?, flags: CGEventFlags, to pid: pid_t?) {
    var characters = Array((character ?? "").utf16)
    for down in [true, false] {
        guard let key = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
        key.flags = flags
        if !characters.isEmpty { key.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters) }
        key.setIntegerValueField(.eventSourceUserData, value: WheelTransformer.ownMarker)
        if let pid { key.postToPid(pid) } else { key.post(tap: .cgSessionEventTap) }
    }
}

/// The key tap for Hold ⌘Q to Quit and Caps Lock as Hyper. It exists only while one of
/// them is on, ScrollSplit is on and both permissions are granted, and it passes every
/// event through untouched unless one of the two claims it. The Caps Lock → F18 mapping is
/// installed only while the tap is, so Caps Lock is never left dead without it.
final class KeyboardEngine {
    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private var gate = HoldToQuitGate()
    private var hyper = HyperKey()
    private let panel = HoldToQuitPanel()
    private let remap = CapsLockRemap()
    private(set) var settings = ScrollSettings()
    /// ScrollSplit's status menu is open: its own ⌘Q (Quit ScrollSplit) must work.
    var ownMenuOpen = false
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }

    func configure(_ newSettings: ScrollSettings) {
        settings = newSettings
        if !(settings.enabled && settings.holdToQuit) { endHold() }
        if !(settings.enabled && settings.capsLockIsHyper) { hyper.reset() }
        guard settings.needsKeyTap, AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            stop()
            return
        }
        if tap == nil { tap = makeTap() }
        remap.setActive(tap != nil && settings.capsLockIsHyper && CapsLockRemap.isAvailable)
    }

    /// Removes the tap and the Caps Lock mapping, and closes any panel.
    func stop() {
        remap.setActive(false)
        if let installed = tap {
            CGEvent.tapEnable(tap: installed.port, enable: false)
            CFMachPortInvalidate(installed.port)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), installed.source, .commonModes)
            tap = nil
        }
        endHold()
        hyper.reset()
    }

    private func makeTap() -> (port: CFMachPort, source: CFRunLoopSource)? {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    private func endHold() {
        if gate.isHolding { panel.hide() }
        gate.reset()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Keys may have been released while the tap was off: start both features clean.
            endHold(); hyper.reset()
            if let tap, settings.needsKeyTap, AXIsProcessTrusted(), CGPreflightListenEventAccess() {
                CGEvent.tapEnable(tap: tap.port, enable: true)
            }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != WheelTransformer.ownMarker else { return pass }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = CACurrentMediaTime()
        let holdToQuit = settings.enabled && settings.holdToQuit
        if type == .flagsChanged {
            if case .cancel = gate.flagsChanged(event.flags) { panel.hide() }
            return pass
        }
        guard type == .keyDown || type == .keyUp else { return pass }
        let isDown = type == .keyDown
        if settings.enabled && settings.capsLockIsHyper {
            switch hyper.key(keyCode: keyCode, isDown: isDown, now: now, tapIsEscape: settings.capsLockTapIsEscape) {
            case .pass: break
            case .swallow: return nil
            case .sendEscape:
                DispatchQueue.main.async { postKeyPress(HyperKey.escapeKeyCode, character: "\u{1B}", flags: [], to: nil) }
                return nil
            case .addHyper:
                event.flags = event.flags.union(HyperKey.flags)
            }
        }
        let action: HoldToQuitGate.Action
        if isDown {
            let front = NSWorkspace.shared.frontmostApplication
            action = gate.keyDown(keyCode: keyCode, flags: event.flags,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                  enabled: holdToQuit, now: now,
                                  frontmost: front.map { QuitTarget(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) },
                                  ownBundleIdentifier: Bundle.main.bundleIdentifier, ownMenuOpen: ownMenuOpen)
        } else {
            action = gate.keyUp(keyCode: keyCode)
        }
        switch action {
        case .pass: return pass
        case .swallow: return nil
        case .cancel(let passEvent):
            panel.hide()
            return passEvent ? pass : nil
        case .begin(let target):
            // The panel and the timer run after the callback returns: no slow work in the tap.
            DispatchQueue.main.async { [weak self] in
                // Released before the panel got this far: nothing to show.
                guard let self, self.gate.isHolding else { return }
                self.panel.show(for: NSRunningApplication(processIdentifier: target.pid))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + HoldToQuitGate.holdDuration) { [weak self] in self?.holdTimerFired() }
            return nil
        }
    }

    private func holdTimerFired() {
        // A stale timer from an earlier, shorter hold finds the new hold not yet complete.
        guard let target = gate.tick(now: CACurrentMediaTime()) else {
            if gate.isHolding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.holdTimerFired() }
            }
            return
        }
        panel.hide()
        postKeyPress(CGKeyCode(HoldToQuitGate.qKeyCode), character: "q", flags: .maskCommand, to: target.pid)
    }
}
