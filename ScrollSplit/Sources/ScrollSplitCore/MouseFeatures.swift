import Foundation
import CoreGraphics

// MARK: Smooth wheel scrolling

/// Which wheel events become a glide. Only discrete notches the engine did not post
/// itself, and never while ⌘, ⌃ or ⌥ is held (zoom and similar gestures in many apps).
/// Shift is allowed: Shift-scroll glides like any other notch.
public enum SmoothScroll {
    public static let passThroughModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    /// Pixels per tick when a notch carries no pixel delta of its own (the system's line height).
    public static let pixelsPerTick: Int64 = 10

    public static func shouldSmooth(enabled: Bool, smoothScrolling: Bool, isContinuous: Bool, isOwnEvent: Bool, flags: CGEventFlags) -> Bool {
        enabled && smoothScrolling && !isContinuous && !isOwnEvent && flags.intersection(passThroughModifiers).isEmpty
    }

    /// The pixel distance a notch would have scrolled had it been passed through.
    public static func notchDistance(point: Int64, tick: Int64) -> Int64 {
        point != 0 ? point : tick * pixelsPerTick
    }

    /// Apps turn Shift-wheel into horizontal scrolling only for notched events, not for
    /// the pixel events a glide posts, so a vertical-only Shift notch glides horizontally
    /// and Shift is dropped from the posted events so no app swaps it back.
    public static func glideAxes(vertical: Int64, horizontal: Int64, flags: CGEventFlags) -> (vertical: Int64, horizontal: Int64, flags: CGEventFlags) {
        guard flags.contains(.maskShift) else { return (vertical, horizontal, flags) }
        var posted = flags
        posted.remove(.maskShift)
        return horizontal == 0 ? (0, vertical, posted) : (vertical, horizontal, posted)
    }

    /// A glide that has gone this long without a frame has lost its display (a screen
    /// went away): drop it rather than swallow every later notch.
    public static let stallLimit = GlideAxis.duration * 2
    public static func isStalled(glideIdle: Bool, lastFrame: Double, now: Double) -> Bool {
        !glideIdle && now - lastFrame > stallLimit
    }
}

/// One axis of a glide. A notch starts an eased-out segment carrying everything not yet
/// delivered plus the new distance, so a burst adds up instead of restarting and the
/// delivered total equals the notch total exactly. A notch in the opposite direction
/// drops what was still owed (the glide stops at once) and starts its own segment.
public struct GlideAxis: Equatable {
    public static let duration = 0.2
    private var total: Int64 = 0
    private var emitted: Int64 = 0
    private var start: Double = 0
    public init() {}

    public var isIdle: Bool { emitted == total }
    public var remaining: Int64 { total - emitted }

    /// Adds a notch at `now`. Returns the distance dropped by a reversal (zero otherwise).
    @discardableResult
    public mutating func add(_ distance: Int64, at now: Double) -> Int64 {
        guard distance != 0 else { return 0 }
        let owed = remaining
        let reversed = owed != 0 && (owed > 0) != (distance > 0)
        let carried = reversed ? 0 : owed
        let limit = Int64(Int32.max)
        total = max(-limit, min(limit, carried + distance))
        emitted = 0
        start = now
        return reversed ? owed : 0
    }

    /// Stops the glide, returning what was still owed.
    @discardableResult
    public mutating func stop() -> Int64 {
        let owed = remaining
        total = 0; emitted = 0
        return owed
    }

    /// The pixels to post for a frame at `now`. The last frame of a segment delivers
    /// whatever rounding held back, so nothing drifts.
    public mutating func step(at now: Double) -> Int64 {
        guard !isIdle else { return 0 }
        let progress = min(1, max(0, (now - start) / Self.duration))
        let target: Int64
        if progress >= 1 {
            target = total
        } else {
            let eased = 1 - pow(1 - progress, 3)
            target = Int64((Double(total) * eased).rounded(.towardZero))
        }
        let output = target - emitted
        emitted = target
        return output
    }
}

/// Vertical (axis 1) and horizontal (axis 2) glides, independent of each other.
public struct ScrollGlide: Equatable {
    public private(set) var vertical = GlideAxis()
    public private(set) var horizontal = GlideAxis()
    public init() {}

    public var isIdle: Bool { vertical.isIdle && horizontal.isIdle }

    @discardableResult
    public mutating func add(vertical v: Int64, horizontal h: Int64, at now: Double) -> (vertical: Int64, horizontal: Int64) {
        (vertical.add(v, at: now), horizontal.add(h, at: now))
    }

    public mutating func step(at now: Double) -> (vertical: Int64, horizontal: Int64) {
        (vertical.step(at: now), horizontal.step(at: now))
    }

    public mutating func stop() { vertical.stop(); horizontal.stop() }
}

// MARK: Back and forward buttons

public enum NavigationCommand: Equatable {
    case back, forward

    /// Virtual key codes for [ and ] (sent with ⌘).
    public var keyCode: CGKeyCode { self == .back ? 0x21 : 0x1E }
    public var character: String { self == .back ? "[" : "]" }
}

/// Claims button 4 (Back) and button 5 (Forward) presses and swallows exactly the
/// releases of presses it claimed. Every other button, and every own event, passes.
public struct SideButtonRouter: Equatable {
    public enum Action: Equatable { case pass, swallow, send(NavigationCommand) }
    /// Quartz numbers buttons from zero, so the fourth and fifth buttons are 3 and 4.
    public static func command(forButton button: Int64) -> NavigationCommand? {
        switch button { case 3: return .back; case 4: return .forward; default: return nil }
    }

    private var claimed: Set<Int64> = []
    public init() {}

    public mutating func handle(isDown: Bool, button: Int64, enabled: Bool, isOwnEvent: Bool) -> Action {
        if isOwnEvent { return .pass }
        if !isDown { return claimed.remove(button) != nil ? .swallow : .pass }
        guard enabled, let command = Self.command(forButton: button) else { return .pass }
        claimed.insert(button)
        return .send(command)
    }

    public mutating func reset() { claimed.removeAll() }
}

// MARK: Pointer acceleration

/// Which HID services count as a mouse: pointing services that are not trackpads,
/// judged by usage (digitizer touch pad), built-in status and the product name.
public enum MouseServiceFilter {
    public static func isMouse(conformsToMouse: Bool, conformsToTouchPad: Bool, isBuiltIn: Bool, product: String?) -> Bool {
        conformsToMouse && !conformsToTouchPad && !isBuiltIn
            && !(product?.range(of: "trackpad", options: .caseInsensitive) != nil)
    }
}

/// Remembers each device's own acceleration the first time it is made linear, so
/// reapplying (on connect or wake) never records the linear value as the original.
public struct AccelerationLedger: Equatable {
    /// HIDMouseAcceleration is 16.16 fixed point; -1 turns acceleration off.
    public static let linear: Int64 = -65_536
    public private(set) var originals: [UInt64: Int64] = [:]
    /// Devices ScrollSplit wrote to. Only these are restored; a device that was already
    /// linear before ScrollSplit looked at it is left exactly as it was.
    public private(set) var touched: Set<UInt64> = []
    public init() {}

    /// Records `current` as the device's original when it is the first sighting and not
    /// already linear. Returns whether the device needs the linear value written.
    public mutating func linearize(device: UInt64, current: Int64?) -> Bool {
        if originals[device] == nil, let current, current != Self.linear { originals[device] = current }
        guard current != Self.linear else { return false }
        touched.insert(device)
        return true
    }

    /// What to write back to each device ScrollSplit changed: its recorded original,
    /// else the system preference. Clears the ledger.
    public mutating func restorations(fallback: Int64) -> [UInt64: Int64] {
        var result: [UInt64: Int64] = [:]
        for device in touched { result[device] = originals[device] ?? fallback }
        originals.removeAll(); touched.removeAll()
        return result
    }

    /// The system's own setting (`com.apple.mouse.scaling`) as a HID property value.
    public static func fixedPoint(scaling: Double?) -> Int64 {
        guard let scaling, scaling.isFinite, (-1...20).contains(scaling) else { return 45_056 } // 0.6875, the macOS default
        return Int64((scaling * 65_536).rounded())
    }
}
