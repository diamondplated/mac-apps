import AppKit
import ApplicationServices
import QuartzCore
import ScrollSplitCore

/// Drives a glide on the refresh of the screen under the pointer. The link exists only
/// while a glide runs and is rebuilt for each new glide, so a screen that went away
/// never strands one.
final class GlideDriver: NSObject {
    private var link: CADisplayLink?
    private(set) var lastFrame = 0.0
    var onFrame: (() -> Void)?

    /// False when there is no screen to synchronise with; the caller then passes the notch through.
    func start() -> Bool {
        if link == nil {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else { return false }
            let created = screen.displayLink(target: self, selector: #selector(frame(_:)))
            created.add(to: .main, forMode: .common)
            link = created
            lastFrame = CACurrentMediaTime()
        }
        return true
    }

    /// Also breaks the link's hold on this target.
    func invalidate() { link?.invalidate(); link = nil }
    @objc private func frame(_ link: CADisplayLink) { lastFrame = CACurrentMediaTime(); onFrame?() }
}

/// Two taps, each installed only while its feature needs it: the scroll tap (direction,
/// speed and smoothing) while ScrollSplit is on, and the button tap only while Back and
/// Forward buttons are on. Both pass every event through untouched unless a feature
/// claims it, and both run on the main run loop.
final class ScrollEngine {
    private var scrollTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var buttonTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var transformer = WheelTransformer(settings: ScrollSettings())
    private var glide = ScrollGlide()
    private var glideFlags: CGEventFlags = []
    private let driver = GlideDriver()
    private var buttons = SideButtonRouter()
    private let acceleration = PointerAcceleration()
    private(set) var settings = ScrollSettings()
    var didChange: ((Bool) -> Void)?
    var active: Bool { scrollTap.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }

    init() { driver.onFrame = { [weak self] in self?.frame() } }

    func configure(_ newSettings: ScrollSettings) {
        if settings != newSettings { transformer = WheelTransformer(settings: newSettings) }
        settings = newSettings
        acceleration.setActive(settings.enabled && settings.mouseAccelerationOff)
        if !(settings.enabled && settings.smoothScrolling) { stopGlide() }
        guard settings.enabled, AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            let wasInstalled = scrollTap != nil
            removeTaps()
            if wasInstalled { didChange?(false) }
            return
        }
        if settings.sideButtonsNavigate {
            if buttonTap == nil {
                buttonTap = makeTap((CGEventMask(1) << CGEventType.otherMouseDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue))
            }
        } else {
            remove(&buttonTap); buttons.reset()
        }
        if scrollTap != nil { return }
        scrollTap = makeTap(CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        didChange?(active)
    }

    /// Removes every tap, stops any glide and restores pointer acceleration.
    func stop() {
        removeTaps()
        stopGlide()
        acceleration.setActive(false)
        didChange?(false)
    }

    private func makeTap(_ mask: CGEventMask) -> (port: CFMachPort, source: CFRunLoopSource)? {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    private func remove(_ tap: inout (port: CFMachPort, source: CFRunLoopSource)?) {
        guard let installed = tap else { return }
        CGEvent.tapEnable(tap: installed.port, enable: false)
        CFMachPortInvalidate(installed.port)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), installed.source, .commonModes)
        tap = nil
    }

    private func removeTaps() {
        remove(&scrollTap)
        remove(&buttonTap)
        buttons.reset()
        stopGlide()
    }

    private func stopGlide() {
        glide.stop()
        driver.invalidate()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if settings.enabled, AXIsProcessTrusted(), CGPreflightListenEventAccess() {
                if let scrollTap { CGEvent.tapEnable(tap: scrollTap.port, enable: true) }
                if let buttonTap, settings.sideButtonsNavigate { CGEvent.tapEnable(tap: buttonTap.port, enable: true) }
            }
            didChange?(active)
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .scrollWheel: return scroll(event)
        case .otherMouseDown, .otherMouseUp: return button(type, event)
        default: return Unmanaged.passUnretained(event)
        }
    }

    private func scroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isOwn = event.getIntegerValueField(.eventSourceUserData) == WheelTransformer.ownMarker
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let flags = event.flags
        transformer.transform(event)
        guard SmoothScroll.shouldSmooth(enabled: settings.enabled, smoothScrolling: settings.smoothScrolling,
                                        isContinuous: isContinuous, isOwnEvent: isOwn, flags: flags) else { return Unmanaged.passUnretained(event) }
        let vertical = SmoothScroll.notchDistance(point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                                                  tick: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let horizontal = SmoothScroll.notchDistance(point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                                                    tick: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let now = CACurrentMediaTime()
        if SmoothScroll.isStalled(glideIdle: glide.isIdle, lastFrame: driver.lastFrame, now: now) { stopGlide() }
        // Fail open: nothing to glide, or no display to glide on, passes the notch through.
        guard vertical != 0 || horizontal != 0, driver.start() else { return Unmanaged.passUnretained(event) }
        let axes = SmoothScroll.glideAxes(vertical: vertical, horizontal: horizontal, flags: flags)
        glide.add(vertical: axes.vertical, horizontal: axes.horizontal, at: now)
        glideFlags = axes.flags
        return nil
    }

    private func frame() {
        let step = glide.step(at: CACurrentMediaTime())
        if step.vertical != 0 || step.horizontal != 0,
           let output = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: Int32(clamping: step.vertical), wheel2: Int32(clamping: step.horizontal), wheel3: 0) {
            output.flags = glideFlags
            output.location = CGEvent(source: nil)?.location ?? output.location
            output.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            output.setIntegerValueField(.eventSourceUserData, value: WheelTransformer.ownMarker)
            output.post(tap: .cgSessionEventTap)
        }
        if glide.isIdle { driver.invalidate() }
    }

    private func button(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isOwn = event.getIntegerValueField(.eventSourceUserData) == WheelTransformer.ownMarker
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = buttons.handle(isDown: type == .otherMouseDown, button: event.getIntegerValueField(.mouseEventButtonNumber),
                                    enabled: settings.enabled && settings.sideButtonsNavigate && target != nil, isOwnEvent: isOwn)
        switch action {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        case .send(let command):
            if let target { send(command, to: target) }
            return nil
        }
    }

    /// ⌘[ or ⌘] to the frontmost app's process only.
    private func send(_ command: NavigationCommand, to pid: pid_t) {
        var characters = Array(command.character.utf16)
        for down in [true, false] {
            guard let key = CGEvent(keyboardEventSource: nil, virtualKey: command.keyCode, keyDown: down) else { continue }
            key.flags = .maskCommand
            key.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
            key.setIntegerValueField(.eventSourceUserData, value: WheelTransformer.ownMarker)
            key.postToPid(pid)
        }
    }
}
