import Foundation
import CoreGraphics

// Pure decisions for the Dock click actions. The event tap feeds these plain
// values; nothing here talks to the window server or Accessibility.

struct DockClickSettings: Equatable {
    var hidesFrontApp = false
    var scrollCyclesWindows = false
    var middleClickOpensWindow = false

    var anyEnabled: Bool { hidesFrontApp || scrollCyclesWindows || middleClickOpensWindow }
}

/// What the Dock reports under the pointer.
struct DockHit: Equatable {
    static let applicationSubrole = "AXApplicationDockItem"

    let subrole: String
    /// The running app the item stands for; nil for an app that is not running,
    /// and for anything that is not an app (Trash, folders, minimized windows).
    let runningPID: pid_t?

    var runningAppPID: pid_t? { subrole == Self.applicationSubrole ? runningPID : nil }
}

enum DockMouseEvent: Equatable {
    case leftDown(clickCount: Int64)
    case leftDragged
    case leftUp
    case otherDown(button: Int64)
    case otherUp(button: Int64)
    case scroll
}

enum DockClickAction: Equatable {
    case hide(pid_t)
    case newWindow(pid_t)
    case cycle(pid_t, direction: Int)
}

struct DockClickDecision: Equatable {
    let consume: Bool
    let action: DockClickAction?
    static let pass = DockClickDecision(consume: false, action: nil)
}

/// Is the point close enough to a screen's bottom, left or right edge to be on the Dock?
/// A cheap filter so a click elsewhere never costs a hit test. Rects and the point use
/// window-server coordinates (origin top-left, y down).
enum DockZone {
    /// Covers the largest Dock with magnification.
    static let thickness: CGFloat = 200

    static func contains(_ point: CGPoint, screens: [CGRect], thickness: CGFloat = thickness) -> Bool {
        guard let screen = screens.first(where: { $0.contains(point) }) else { return false }
        return point.y >= screen.maxY - thickness
            || point.x <= screen.minX + thickness
            || point.x >= screen.maxX - thickness
    }
}

/// Decides every Dock-bound mouse event. Owned by the tap's thread.
struct DockClickRouter {
    static let middleButton: Int64 = 2
    static let clickDuration: TimeInterval = 0.4
    static let clickSlop: CGFloat = 4

    private struct Press {
        let pid: pid_t
        let location: CGPoint
        let time: TimeInterval
    }

    var settings = DockClickSettings()
    private var press: Press?
    /// When the swallowed middle press happened; its release is swallowed too, unless
    /// it never arrives in time (the tap was briefly disabled) and the flag goes stale.
    private var swallowMiddleUpSince: TimeInterval?
    static let middleReleaseTimeout: TimeInterval = 5
    private(set) var scroll = ScrollStepAccumulator()

    /// Modifier keys that make a click something other than a plain click.
    static func hasModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    /// Whether an event is worth one Dock hit test. Everything else passes untouched.
    func needsHitTest(_ event: DockMouseEvent, flags: CGEventFlags) -> Bool {
        switch event {
        case .leftDown(let clicks): return settings.hidesFrontApp && clicks == 1 && !Self.hasModifiers(flags)
        case .otherDown(let button): return settings.middleClickOpensWindow && button == Self.middleButton && !Self.hasModifiers(flags)
        case .scroll: return settings.scrollCyclesWindows && !Self.hasModifiers(flags)
        case .leftDragged, .leftUp, .otherUp: return false
        }
    }

    /// - Parameters:
    ///   - hit: the Dock item under the pointer; nil when nothing was hit or no test ran.
    ///   - frontmostPID: the app that is frontmost before the Dock sees this event.
    ///   - frontAppHasVisibleWindow: whether that app shows a window now. A click on the
    ///     icon of an app whose windows are all minimized restores one; that stays the Dock's.
    mutating func decide(
        _ event: DockMouseEvent,
        flags: CGEventFlags,
        location: CGPoint,
        time: TimeInterval,
        hit: DockHit?,
        frontmostPID: pid_t?,
        frontAppHasVisibleWindow: Bool = true,
        scrollSample: ScrollStepAccumulator.Sample? = nil
    ) -> DockClickDecision {
        switch event {
        case .leftDown(let clicks):
            press = nil
            guard settings.hidesFrontApp, clicks == 1, !Self.hasModifiers(flags),
                  let pid = hit?.runningAppPID, pid == frontmostPID, frontAppHasVisibleWindow else { return .pass }
            // The press still goes to the Dock; only a quick release in place hides the app.
            press = Press(pid: pid, location: location, time: time)
            return .pass
        case .leftDragged:
            if let press, distance(press.location, location) > Self.clickSlop { self.press = nil }
            return .pass
        case .leftUp:
            defer { press = nil }
            guard settings.hidesFrontApp, let press, !Self.hasModifiers(flags),
                  time - press.time <= Self.clickDuration,
                  distance(press.location, location) <= Self.clickSlop else { return .pass }
            return DockClickDecision(consume: false, action: .hide(press.pid))
        case .otherDown(let button):
            swallowMiddleUpSince = nil
            guard settings.middleClickOpensWindow, button == Self.middleButton, !Self.hasModifiers(flags),
                  let pid = hit?.runningAppPID else { return .pass }
            swallowMiddleUpSince = time
            return DockClickDecision(consume: true, action: .newWindow(pid))
        case .otherUp(let button):
            guard button == Self.middleButton, let since = swallowMiddleUpSince else { return .pass }
            swallowMiddleUpSince = nil
            guard time - since <= Self.middleReleaseTimeout else { return .pass }
            return DockClickDecision(consume: true, action: nil)
        case .scroll:
            // A modified scroll (⌃-scroll zooms) stays the system's.
            guard settings.scrollCyclesWindows, !Self.hasModifiers(flags), let pid = hit?.runningAppPID, let scrollSample else {
                scroll.reset()
                return .pass
            }
            let step = scroll.add(scrollSample, pid: pid)
            return DockClickDecision(consume: true, action: step.map { .cycle(pid, direction: $0) })
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Turns a stream of scroll events into deliberate steps.
///
/// A mouse wheel gives one step per notch, at most one per `wheelInterval`. A trackpad
/// gives one step per gesture once it has travelled `gestureThreshold` points, and its
/// momentum never steps, so a flick cannot spin through every window.
struct ScrollStepAccumulator {
    static let gestureThreshold: Double = 24
    static let wheelInterval: TimeInterval = 0.15
    static let gestureGap: TimeInterval = 0.5

    struct Sample: Equatable {
        /// Vertical and horizontal deltas: lines for a wheel, points for a trackpad.
        let deltaY: Double
        let deltaX: Double
        let isContinuous: Bool
        /// The event's scroll phase (`kCGScrollWheelEventScrollPhase`); 0 for a wheel.
        let phase: Int64
        /// Nonzero for momentum after the fingers lift.
        let momentumPhase: Int64
        let time: TimeInterval
    }

    enum Phase {
        static let began: Int64 = 1
        static let ended: Int64 = 4
        static let cancelled: Int64 = 8
        static let mayBegin: Int64 = 128
    }

    private var pid: pid_t?
    private var travelled: Double = 0
    private var steppedThisGesture = false
    private var lastEvent: TimeInterval = -.infinity
    private var lastStep: TimeInterval = -.infinity

    mutating func reset() {
        pid = nil
        travelled = 0
        steppedThisGesture = false
    }

    /// Returns +1 (next window), -1 (previous window) or nil.
    mutating func add(_ sample: Sample, pid: pid_t) -> Int? {
        if self.pid != pid {
            reset()
            self.pid = pid
        }
        defer { lastEvent = sample.time }
        let delta = abs(sample.deltaX) > abs(sample.deltaY) ? sample.deltaX : sample.deltaY
        // Scrolling down (negative delta) moves to the next window.
        let direction = delta < 0 ? 1 : -1

        // A smooth-scrolling mouse is continuous but has no gesture phases: treat it as a wheel.
        let isGesture = sample.isContinuous && (sample.phase != 0 || sample.momentumPhase != 0)
        guard isGesture else {
            guard delta != 0, sample.time - lastStep >= Self.wheelInterval else { return nil }
            lastStep = sample.time
            return direction
        }

        if sample.momentumPhase != 0 { return nil }
        if sample.phase == Phase.began || sample.phase == Phase.mayBegin || sample.time - lastEvent > Self.gestureGap {
            travelled = 0
            steppedThisGesture = false
        }
        if sample.phase == Phase.ended || sample.phase == Phase.cancelled {
            travelled = 0
            steppedThisGesture = false
            return nil
        }
        travelled += delta
        guard !steppedThisGesture, abs(travelled) >= Self.gestureThreshold else { return nil }
        steppedThisGesture = true
        lastStep = sample.time
        return travelled < 0 ? 1 : -1
    }
}

/// Keeps a stable order while scrolling through one app's windows; otherwise raising
/// the second window would make it first and the next step would just go back.
struct WindowCycle {
    static let sessionTimeout: TimeInterval = 1.5

    private var pid: pid_t?
    private var order: [CGWindowID] = []
    private var index = 0
    private var lastStep: TimeInterval = -.infinity

    /// - Parameter windows: the app's windows now, front to back.
    /// - Returns: the window to raise.
    mutating func step(pid: pid_t, windows: [CGWindowID], appIsFrontmost: Bool, direction: Int, now: TimeInterval) -> CGWindowID? {
        guard !windows.isEmpty else { return nil }
        let continuing = self.pid == pid && now - lastStep <= Self.sessionTimeout
        lastStep = now
        if continuing {
            let current = order.indices.contains(index) ? order[index] : nil
            let present = Set(windows)
            order = order.filter { present.contains($0) } + windows.filter { !order.contains($0) }
            index = current.flatMap { order.firstIndex(of: $0) } ?? 0
        } else {
            self.pid = pid
            order = windows
            index = 0
            // An app in the background comes forward with its front window first.
            if !appIsFrontmost { return order[0] }
        }
        index = SwitcherSelection.step(from: index, by: direction, count: order.count) ?? 0
        return order[index]
    }
}
