import Foundation
import CoreGraphics

/// ⌘X then ⌘V moves files in Finder. Finder only moves with ⌘C then ⌥⌘V, so while the
/// switch is on and Finder is in front, ⌘X is sent on as ⌘C and remembered, and the next
/// ⌘V is sent on as ⌥⌘V. Nothing here moves a file: Finder does, and this only changes
/// which shortcut it sees. Every doubt passes the key through untouched.
public struct FinderCut: Equatable {
    public static let finderBundleIdentifier = "com.apple.finder"
    public static let xKeyCode: Int64 = 7
    public static let vKeyCode: Int64 = 9
    /// The Accessibility messaging timeout for the one focus query.
    public static let focusTimeout: Float = 0.1
    /// How long after sending ⌘C the clipboard is read, in seconds.
    public static let copySettleDelay = 0.25
    /// Roles that take typed text, where ⌘X and ⌘V mean cut and paste text.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

    /// What the one Accessibility query for Finder's focused element answered.
    public enum Focus: Equatable {
        case text, notText, timeout, error

        /// The role of the focused element; a missing role is an error, not "not text".
        public static func from(role: String?) -> Focus {
            guard let role else { return .error }
            return FinderCut.textRoles.contains(role) ? .text : .notText
        }
    }

    public enum Action: Equatable {
        case pass
        /// Swallow the key and send nothing (a repeat or release of a key already claimed).
        case swallow
        /// Swallow ⌘X, send ⌘C to Finder, then call `copyFinished` after the settle delay.
        case copy(generation: Int, changeCountBefore: Int)
        /// Swallow ⌘V and send ⌥⌘V to Finder.
        case move
    }

    /// The clipboard change count just after the copy; while it still matches, the
    /// clipboard holds what was cut.
    public private(set) var pending: Int?
    private var generation = 0
    private var claimedKey: Int64?
    public init() {}

    /// `focus` is only called when the answer matters, so the Accessibility query runs
    /// at most once, and not at all for any other key.
    public mutating func keyDown(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool, enabled: Bool, isOwnEvent: Bool,
                                 frontmostBundleIdentifier: String?, changeCount: Int, focus: () -> Focus) -> Action {
        guard enabled else { reset(); return .pass }
        guard !isOwnEvent else { return .pass }
        // A repeat never starts anything: it follows the claim of the press before it, or passes.
        if isRepeat { return claimedKey == keyCode ? .swallow : .pass }
        guard frontmostBundleIdentifier == Self.finderBundleIdentifier,
              flags.intersection(shortcutModifiers) == .maskCommand,
              keyCode == Self.xKeyCode || keyCode == Self.vKeyCode else { return .pass }
        if keyCode == Self.vKeyCode {
            guard let remembered = pending else { return .pass }
            guard remembered == changeCount else { pending = nil; return .pass } // the clipboard moved on
            guard focus() == .notText else { return .pass }
            pending = nil // a cut is used once
            claimedKey = keyCode
            return .move
        }
        guard focus() == .notText else { return .pass }
        pending = nil
        generation += 1
        claimedKey = keyCode
        return .copy(generation: generation, changeCountBefore: changeCount)
    }

    /// Releases of a key this struct claimed are swallowed so Finder never sees an
    /// unmatched key-up.
    public mutating func keyUp(keyCode: Int64) -> Action {
        guard claimedKey == keyCode else { return .pass }
        claimedKey = nil
        return .swallow
    }

    /// Called after the copy settled. The cut is remembered only if the clipboard really
    /// changed (an empty selection copies nothing) and no newer ⌘X or reset happened.
    public mutating func copyFinished(generation finished: Int, changeCountBefore: Int, changeCountNow: Int) {
        guard finished == generation, changeCountNow != changeCountBefore else { return }
        pending = changeCountNow
    }

    /// The switch went off, the tap went away or was disabled.
    public mutating func reset() {
        pending = nil
        claimedKey = nil
        generation += 1
    }
}
