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
    private var cut = FinderCut()
    private let panel = HoldToQuitPanel()
    private let remap = CapsLockRemap()
    private(set) var settings = ScrollSettings()
    /// ScrollSplit's status menu is open: its own ⌘Q (Quit ScrollSplit) must work.
    var ownMenuOpen = false
    private var holdTarget: pid_t?
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }

    func configure(_ newSettings: ScrollSettings) {
        settings = newSettings
        if !(settings.enabled && settings.holdToQuit) { endHold() }
        if !(settings.enabled && settings.capsLockIsHyper) { hyper.reset() }
        if !(settings.enabled && settings.cutAndPasteFilesInFinder) { cut.reset() }
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
        cut.reset()
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
            endHold(); hyper.reset(); cut.reset()
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
            // A Caps Lock release the tap never saw (secure input) must not leave Hyper stuck on:
            // the remap is at the HID level, so the HID state knows whether F18 is really down.
            if hyper.isHeld, keyCode != HyperKey.f18KeyCode,
               !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(HyperKey.f18KeyCode)) { hyper.reset() }
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
        if let claimed = handleFinderCut(isDown: isDown, keyCode: keyCode, event: event) { return claimed ? nil : pass }
        let action: HoldToQuitGate.Action
        if isDown {
            action = gate.keyDown(keyCode: keyCode, flags: event.flags,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                  enabled: holdToQuit, now: now,
                                  frontmost: { NSWorkspace.shared.frontmostApplication.map { QuitTarget(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) } },
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
            holdTarget = target.pid
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

    /// Cut and paste files in Finder. Returns true to swallow the event, false to pass it, nil
    /// when the feature has nothing to say (the other features then look at the key).
    private func handleFinderCut(isDown: Bool, keyCode: Int64, event: CGEvent) -> Bool? {
        guard isDown else { return cut.keyUp(keyCode: keyCode) == .swallow ? true : nil }
        let enabled = settings.enabled && settings.cutAndPasteFilesInFinder
        // The clipboard and the front app are read only for the two keys that could matter.
        let relevant = enabled && (keyCode == FinderCut.xKeyCode || keyCode == FinderCut.vKeyCode)
        let front = relevant ? NSWorkspace.shared.frontmostApplication : nil
        let action = cut.keyDown(keyCode: keyCode, flags: event.flags,
                                 isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                 enabled: enabled, isOwnEvent: false,
                                 frontmostBundleIdentifier: front?.bundleIdentifier,
                                 changeCount: relevant ? NSPasteboard.general.changeCount : 0,
                                 focus: { Self.finderFocus(pid: front?.processIdentifier) })
        switch action {
        case .pass: return nil
        case .swallow: return true
        case .copy(let generation, let before):
            guard let pid = front?.processIdentifier else { return nil }
            // Posting and the settle check run after the callback returns: no slow work in the tap.
            DispatchQueue.main.async { postKeyPress(8, character: "c", flags: .maskCommand, to: pid) }
            DispatchQueue.main.asyncAfter(deadline: .now() + FinderCut.copySettleDelay) { [weak self] in
                self?.cut.copyFinished(generation: generation, changeCountBefore: before,
                                       changeCountNow: NSPasteboard.general.changeCount)
            }
            return true
        case .move:
            guard let pid = front?.processIdentifier else { return nil }
            DispatchQueue.main.async { postKeyPress(CGKeyCode(FinderCut.vKeyCode), character: "v", flags: [.maskCommand, .maskAlternate], to: pid) }
            return true
        }
    }

    /// One Accessibility query for the role of Finder's focused element, with a short
    /// messaging timeout. Anything but a clear answer reads as timeout or error: pass the key.
    private static func finderFocus(pid: pid_t?) -> FinderCut.Focus {
        guard let pid else { return .error }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FinderCut.focusTimeout)
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if focusError == .cannotComplete { return .timeout }
        guard focusError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .error }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FinderCut.focusTimeout)
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if roleError == .cannotComplete { return .timeout }
        guard roleError == .success else { return .error }
        return FinderCut.Focus.from(role: role as? String)
    }

    private func holdTimerFired() {
        // The user switched apps mid-hold: quit nothing.
        if gate.isHolding, NSWorkspace.shared.frontmostApplication?.processIdentifier != holdTarget {
            gate.abandon(); panel.hide(); return
        }
        // A stale timer from an earlier, shorter hold finds the new hold not yet complete.
        guard let target = gate.tick(now: CACurrentMediaTime()) else {
            if gate.isHolding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.holdTimerFired() }
            }
            return
        }
        panel.hide()
        // Only the app that is still in front, and still running, is quit.
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == target.pid, !front.isTerminated else { return }
        postKeyPress(CGKeyCode(HoldToQuitGate.qKeyCode), character: "q", flags: .maskCommand, to: target.pid)
    }
}
