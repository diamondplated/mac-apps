import Foundation
import CoreGraphics

/// The four modifiers a shortcut is judged by. Caps Lock, Fn and the device-specific
/// bits are ignored.
public let shortcutModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

// MARK: Hold ⌘Q to quit

/// The app that would receive ⌘Q.
public struct QuitTarget: Equatable {
    public let pid: Int32
    public let bundleIdentifier: String?
    public init(pid: Int32, bundleIdentifier: String?) { self.pid = pid; self.bundleIdentifier = bundleIdentifier }
}

/// Swallows ⌘Q and quits the frontmost app only once ⌘Q has been held for `holdDuration`.
/// Every event the gate does not claim passes untouched, and anything unexpected during a
/// hold (another key, a modifier change, the feature switching off) cancels it.
public struct HoldToQuitGate: Equatable {
    public static let qKeyCode: Int64 = 12
    public static let holdDuration = 0.8
    /// ⌘Q does nothing in the Finder, so holding there would only add a panel.
    public static let exemptBundleIdentifiers: Set<String> = ["com.apple.finder"]

    public enum Action: Equatable {
        case pass
        case swallow
        /// Swallow, show the panel for this app and start the hold.
        case begin(QuitTarget)
        /// Close the panel; `passEvent` says whether the event that cancelled goes on.
        case cancel(passEvent: Bool)
    }

    enum State: Equatable {
        case idle
        case holding(target: QuitTarget, since: Double)
        /// The Q key ScrollSplit claimed is still down (the hold ended, or ⌘Q was sent):
        /// every Q event is swallowed until its release, whatever the modifiers, so letting
        /// go of ⌘ first never types "q" and no unmatched release reaches the app.
        case releasing
    }

    private(set) var state = State.idle
    public init() {}

    public var isHolding: Bool { if case .holding = state { return true } else { return false } }

    public static func isCommandQ(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == qKeyCode && flags.intersection(shortcutModifiers) == .maskCommand
    }

    public static func isExempt(_ target: QuitTarget?, ownBundleIdentifier: String?, ownMenuOpen: Bool) -> Bool {
        guard let target, !ownMenuOpen else { return true }
        guard let identifier = target.bundleIdentifier else { return false }
        return exemptBundleIdentifiers.contains(identifier) || identifier == ownBundleIdentifier
    }

    /// `frontmost` is asked for only when the key is ⌘Q, so other keys cost nothing.
    public mutating func keyDown(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool, enabled: Bool, now: Double,
                                 frontmost: () -> QuitTarget?, ownBundleIdentifier: String?, ownMenuOpen: Bool) -> Action {
        let commandQ = Self.isCommandQ(keyCode: keyCode, flags: flags)
        switch state {
        case .holding:
            if commandQ && enabled { return .swallow }
            state = .releasing
            return .cancel(passEvent: keyCode != Self.qKeyCode)
        case .releasing:
            if keyCode == Self.qKeyCode && isRepeat { return .swallow }
            // Any other key passes. A fresh Q press means its release was never seen (secure
            // input, a tap pause): start over rather than swallow Q forever.
            if keyCode != Self.qKeyCode { return .pass }
            state = .idle
        case .idle:
            break
        }
        guard enabled, commandQ else { return .pass }
        let target = frontmost()
        guard !Self.isExempt(target, ownBundleIdentifier: ownBundleIdentifier, ownMenuOpen: ownMenuOpen), let target else { return .pass }
        // A repeat with no hold in progress belongs to a press that already ended a hold:
        // it must not quit, and it must not start a new hold either.
        if isRepeat { return .swallow }
        state = .holding(target: target, since: now)
        return .begin(target)
    }

    public mutating func keyUp(keyCode: Int64) -> Action {
        guard keyCode == Self.qKeyCode else { return .pass }
        switch state {
        case .holding: state = .idle; return .cancel(passEvent: false)
        case .releasing: state = .idle; return .swallow
        case .idle: return .pass
        }
    }

    /// Releasing ⌘, or adding ⇧, ⌃ or ⌥, ends the hold. Modifier events always pass.
    public mutating func flagsChanged(_ flags: CGEventFlags) -> Action {
        guard case .holding = state, flags.intersection(shortcutModifiers) != .maskCommand else { return .pass }
        state = .releasing
        return .cancel(passEvent: true)
    }

    /// Called when the hold timer fires. Returns the app to quit when the hold is complete.
    public mutating func tick(now: Double) -> QuitTarget? {
        guard case .holding(let target, let since) = state, now - since >= Self.holdDuration else { return nil }
        state = .releasing
        return target
    }

    /// The app in front changed before the hold completed: end it without quitting.
    public mutating func abandon() { if isHolding { state = .releasing } }

    /// The feature switched off, the tap went away or the panel was torn down.
    public mutating func reset() { state = .idle }
}

// MARK: Caps Lock as Hyper

/// While F18 (Caps Lock, remapped) is held, adds ⌃⌥⇧⌘ to every other key, and swallows
/// F18 itself. A quick lone tap optionally becomes Escape.
public struct HyperKey: Equatable {
    public static let f18KeyCode: Int64 = 0x4F
    public static let escapeKeyCode: CGKeyCode = 0x35
    public static let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    /// A tap is a press and release within this long, with no other key in between.
    public static let tapLimit = 0.3

    public enum Action: Equatable { case pass, swallow, addHyper, sendEscape }

    private var downAt: Double?
    private var usedWithOtherKey = false
    public init() {}

    public var isHeld: Bool { downAt != nil }

    public mutating func key(keyCode: Int64, isDown: Bool, now: Double, tapIsEscape: Bool) -> Action {
        if keyCode == Self.f18KeyCode {
            if isDown {
                // Repeats while held keep the first press's time.
                if downAt == nil { downAt = now; usedWithOtherKey = false }
                return .swallow
            }
            let pressed = downAt
            downAt = nil
            if tapIsEscape, let pressed, !usedWithOtherKey, now - pressed <= Self.tapLimit { return .sendEscape }
            return .swallow
        }
        guard downAt != nil else { return .pass }
        if isDown { usedWithOtherKey = true }
        return .addHyper
    }

    public mutating func reset() { downAt = nil; usedWithOtherKey = false }
}

// MARK: Caps Lock to F18 key mapping

/// One `UserKeyMapping` entry: HID usage page in the high 32 bits, usage in the low.
public struct KeyMappingEntry: Codable, Hashable {
    public static let sourceKey = "HIDKeyboardModifierMappingSrc"
    public static let destinationKey = "HIDKeyboardModifierMappingDst"
    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D
    /// The one entry ScrollSplit adds.
    public static let capsLockToF18 = KeyMappingEntry(source: capsLock, destination: f18)

    public let source: UInt64
    public let destination: UInt64
    public init(source: UInt64, destination: UInt64) { self.source = source; self.destination = destination }

    /// Reads a device's `UserKeyMapping` property; unreadable entries are kept as they were
    /// by the caller never rewriting a device it could not parse.
    public static func parse(_ property: Any?) -> [KeyMappingEntry]? {
        guard let property else { return [] }
        guard let array = property as? [Any] else { return nil }
        var result: [KeyMappingEntry] = []
        for item in array {
            guard let dictionary = item as? [String: Any],
                  let source = (dictionary[sourceKey] as? NSNumber)?.uint64Value,
                  let destination = (dictionary[destinationKey] as? NSNumber)?.uint64Value else { return nil }
            result.append(KeyMappingEntry(source: source, destination: destination))
        }
        return result
    }

    public static func property(_ entries: [KeyMappingEntry]) -> [[String: NSNumber]] {
        entries.map { [sourceKey: NSNumber(value: $0.source), destinationKey: NSNumber(value: $0.destination)] }
    }
}

/// Remembers, per keyboard, whether ScrollSplit added Caps Lock → F18 and which Caps Lock
/// mapping of the user's it displaced, so turning off removes exactly what was added.
/// Codable so a crash can be cleaned up at the next launch.
public struct KeyMappingLedger: Codable, Equatable {
    public private(set) var touched: Set<UInt64> = []
    public private(set) var displaced: [UInt64: KeyMappingEntry] = [:]
    public init() {}

    public var isEmpty: Bool { touched.isEmpty }

    /// The mapping to write to `device`, or nil when nothing needs writing (already mapped,
    /// by ScrollSplit earlier or by the user themselves).
    public mutating func adding(device: UInt64, current: [KeyMappingEntry]) -> [KeyMappingEntry]? {
        guard !current.contains(.capsLockToF18) else { return nil }
        // What this write displaces, which is what removing it must put back. A device whose
        // mapping went away and came back is judged afresh.
        displaced[device] = current.first(where: { $0.source == KeyMappingEntry.capsLock })
        touched.insert(device)
        return current.filter { $0.source != KeyMappingEntry.capsLock } + [.capsLockToF18]
    }

    /// The mapping to write back to `device`, or nil to leave it alone: a device ScrollSplit
    /// never changed, or whose Caps Lock → F18 entry is already gone (replugged, rebooted,
    /// or changed by someone else since).
    public func removing(device: UInt64, current: [KeyMappingEntry]) -> [KeyMappingEntry]? {
        guard touched.contains(device), current.contains(.capsLockToF18) else { return nil }
        var result = current.filter { $0 != .capsLockToF18 }
        if let theirs = displaced[device] { result.append(theirs) }
        return result
    }

    public mutating func clear() { touched.removeAll(); displaced.removeAll() }
}
