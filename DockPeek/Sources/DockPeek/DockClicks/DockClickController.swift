import Cocoa
import ApplicationServices

/// Owns the Dock click tap: installs it only while at least one Dock action is on,
/// listens only for the event types those actions need, and acts on the main thread.
final class DockClickController {
    private let hitTester = DockHitTester()
    private let windowService = WindowService.shared
    private var tap: EventTap?
    private var installedSettings = DockClickSettings()
    private var observers: [NSObjectProtocol] = []
    private var cycle = WindowCycle()

    // Read on the tap thread, written on the main thread.
    private let lock = NSLock()
    private var router = DockClickRouter()
    private var screens: [CGRect] = []
    private var frontmostPID: pid_t?

    private var lastScrollHit: (point: CGPoint, time: TimeInterval, hit: DockHit?)?

    deinit { stop() }

    /// Applies the settings: installs, rebuilds or removes the tap.
    func apply(_ settings: DockClickSettings, accessibilityGranted: Bool) {
        let wanted = accessibilityGranted && settings.anyEnabled
        guard !wanted || tap == nil || installedSettings != settings else { return }
        stop()
        guard wanted else { return }
        installedSettings = settings
        lock.lock()
        router = DockClickRouter()
        router.settings = settings
        lock.unlock()
        startObserving()

        let tap = EventTap(events: Self.eventTypes(for: settings)) { [weak self] type, event in
            self?.handle(type, event) ?? false
        }
        if tap.start() { self.tap = tap } else { stopObserving() }
    }

    /// Only the event types the switched-on actions need; right clicks are never tapped.
    static func eventTypes(for settings: DockClickSettings) -> [CGEventType] {
        var events: [CGEventType] = []
        if settings.hidesFrontApp { events += [.leftMouseDown, .leftMouseDragged, .leftMouseUp] }
        if settings.middleClickOpensWindow { events += [.otherMouseDown, .otherMouseUp] }
        if settings.scrollCyclesWindows { events.append(.scrollWheel) }
        return events
    }

    func stop() {
        tap?.stop()
        tap = nil
        installedSettings = DockClickSettings()
        stopObserving()
    }

    // MARK: - Main thread state

    private func startObserving() {
        refreshState()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshState() })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshState() })
    }

    private func stopObserving() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func refreshState() {
        hitTester.refresh()
        let frames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return CGDisplayBounds(number)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.lock()
        screens = frames
        frontmostPID = front
        lock.unlock()
    }

    // MARK: - Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let mouseEvent: DockMouseEvent
        switch type {
        case .leftMouseDown: mouseEvent = .leftDown(clickCount: event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseDragged: mouseEvent = .leftDragged
        case .leftMouseUp: mouseEvent = .leftUp
        case .otherMouseDown: mouseEvent = .otherDown(button: event.getIntegerValueField(.mouseEventButtonNumber))
        case .otherMouseUp: mouseEvent = .otherUp(button: event.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel: mouseEvent = .scroll
        default: return false
        }
        let location = event.location
        let flags = event.flags
        let time = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let needsHit = router.needsHitTest(mouseEvent, flags: flags) && DockZone.contains(location, screens: screens)
        let front = frontmostPID
        lock.unlock()

        var hit: DockHit?
        if needsHit {
            if mouseEvent == .scroll, let last = lastScrollHit,
               hypot(last.point.x - location.x, last.point.y - location.y) < 1, time - last.time < 0.5 {
                // The pointer has not moved during this scroll; reuse the hit.
                hit = last.hit
            } else {
                hit = hitTester.hit(at: location)
                if mouseEvent == .scroll { lastScrollHit = (location, time, hit) }
            }
        }

        var hasVisibleWindow = true
        if case .leftDown = mouseEvent, let pid = hit?.runningAppPID, pid == front {
            // Snapshot before the Dock sees the press, which could restore a minimized window.
            hasVisibleWindow = Self.hasOnScreenWindow(pid: pid)
        }

        var sample: ScrollStepAccumulator.Sample?
        if mouseEvent == .scroll {
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            sample = ScrollStepAccumulator.Sample(
                deltaY: continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                deltaX: continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                isContinuous: continuous,
                phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                time: time
            )
        }

        lock.lock()
        let decision = router.decide(
            mouseEvent, flags: flags, location: location, time: time, hit: hit,
            frontmostPID: front, frontAppHasVisibleWindow: hasVisibleWindow, scrollSample: sample
        )
        lock.unlock()

        if let action = decision.action {
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
        return decision.consume
    }

    /// One window-server query, made only for a press on the frontmost app's own icon.
    private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    // MARK: - Actions (main thread)

    private func perform(_ action: DockClickAction) {
        switch action {
        case .hide(let pid):
            // Recheck: the app must still be the frontmost one.
            guard let app = NSRunningApplication(processIdentifier: pid), app.isActive || NSWorkspace.shared.frontmostApplication == app else { return }
            app.hide()
        case .newWindow(let pid):
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            windowService.activate(app)
            // ⌘N goes to that app's process only, never to whatever else is frontmost.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.postCommandN(to: pid)
            }
        case .cycle(let pid, let direction):
            cycleWindows(of: pid, direction: direction)
        }
    }

    private func cycleWindows(of pid: pid_t, direction: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let windows = windowService.cyclableWindows(for: pid)
        guard let target = cycle.step(
            pid: pid, windows: windows.map(\.id),
            appIsFrontmost: NSWorkspace.shared.frontmostApplication == app,
            direction: direction, now: ProcessInfo.processInfo.systemUptime
        ), let window = windows.first(where: { $0.id == target }) else { return }
        windowService.raiseWindow(window)
    }

    private static func postCommandN(to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        let keyN: CGKeyCode = 45
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }
}
