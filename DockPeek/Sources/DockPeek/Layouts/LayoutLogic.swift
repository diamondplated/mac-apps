import Foundation
import CoreGraphics
import CryptoKit

// Every decision the window-layout feature makes lives here as a pure function:
// which arrangement the displays form, which remembered window belongs to which
// open one, where a window goes on a display that may have changed size, and when
// a burst of changes has gone quiet. The system calls are in LayoutSystem.swift.

/// A connected display as the system reports it, in global top-left coordinates
/// (the same space Accessibility uses for window positions).
struct RawDisplay: Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isBuiltIn: Bool
    let frame: CGRect
    let visibleFrame: CGRect
}

/// A display with a stable identity.
struct DisplayInfo: Equatable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

enum DisplayIdentity {
    /// Stable identities: the built-in display is `builtin`; others are a short hash of
    /// vendor, model and serial, so no serial number is stored. Identical displays that
    /// report the same identity are told apart by position (left to right, then top to bottom).
    static func displays(from raw: [RawDisplay]) -> [DisplayInfo] {
        let base = raw.map { display -> String in
            display.isBuiltIn ? "builtin" : hash("\(display.vendor)-\(display.model)-\(display.serial)")
        }
        var groups: [String: [Int]] = [:]
        for (index, id) in base.enumerated() { groups[id, default: []].append(index) }
        var ids = base
        for (id, indexes) in groups where indexes.count > 1 {
            let ordered = indexes.sorted {
                let a = raw[$0].frame.origin, b = raw[$1].frame.origin
                return a.x != b.x ? a.x < b.x : a.y < b.y
            }
            for (n, index) in ordered.enumerated() { ids[index] = "\(id)#\(n + 1)" }
        }
        return raw.enumerated().map { DisplayInfo(id: ids[$0.offset], frame: $0.element.frame, visibleFrame: $0.element.visibleFrame) }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

enum Arrangement {
    /// The same displays in the same relative places give the same key, however the system
    /// numbers them, wherever the origin sits, and at any resolution. Position is the display's
    /// rank among the distinct left edges and top edges, so swapping two displays, stacking
    /// instead of side by side, or a missing display all change the key.
    static func key(for displays: [DisplayInfo]) -> String {
        guard !displays.isEmpty else { return "none" }
        let xs = Array(Set(displays.map { Int($0.frame.minX.rounded()) })).sorted()
        let ys = Array(Set(displays.map { Int($0.frame.minY.rounded()) })).sorted()
        let parts = displays.map { display -> String in
            let x = xs.firstIndex(of: Int(display.frame.minX.rounded())) ?? 0
            let y = ys.firstIndex(of: Int(display.frame.minY.rounded())) ?? 0
            return "\(display.id)@\(x),\(y)"
        }.sorted()
        return DisplayIdentity.hash(parts.joined(separator: "|"))
    }
}

/// One remembered window: where it was, as fractions of the display it was on.
struct RememberedWindow: Codable, Equatable {
    var bundleID: String
    var title: String
    /// Position among that app's windows when remembered (Accessibility order).
    var order: Int
    var display: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// When this entry was last confirmed by a live window (seconds since 1970); the cap drops the oldest first.
    var updated: TimeInterval = 0
}

/// What matching needs to know about an open window.
struct OpenWindowRef: Equatable {
    let bundleID: String
    let title: String
    let order: Int
}

enum WindowMatcher {
    /// Pairs open windows with remembered ones. Returns open index to remembered index.
    ///
    /// Per app: windows with the same title pair up, in order, when both sides have the same
    /// number of them. Whatever is left pairs by window order only when exactly one remembered
    /// entry and exactly one open window remain; with two or more on either side the pairing
    /// would be a guess, so those windows are left alone.
    static func match(remembered: [RememberedWindow], open: [OpenWindowRef]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        let openByApp = Dictionary(grouping: open.indices, by: { open[$0].bundleID })
        let rememberedByApp = Dictionary(grouping: remembered.indices, by: { remembered[$0].bundleID })
        for (bundle, openIndexes) in openByApp {
            guard let rememberedIndexes = rememberedByApp[bundle] else { continue }
            let openSorted = openIndexes.sorted { open[$0].order < open[$1].order }
            let rememberedSorted = rememberedIndexes.sorted { remembered[$0].order < remembered[$1].order }
            var usedRemembered = Set<Int>()
            var pairedOpen = Set<Int>()

            let openTitles = Dictionary(grouping: openSorted, by: { open[$0].title })
            let rememberedTitles = Dictionary(grouping: rememberedSorted, by: { remembered[$0].title })
            for (title, opens) in openTitles {
                guard let remembers = rememberedTitles[title], opens.count == remembers.count else { continue }
                for (o, r) in zip(opens, remembers) {
                    result[o] = r; usedRemembered.insert(r); pairedOpen.insert(o)
                }
            }

            let leftOpen = openSorted.filter { !pairedOpen.contains($0) }
            let leftRemembered = rememberedSorted.filter { !usedRemembered.contains($0) }
            if leftOpen.count == 1, leftRemembered.count == 1 {
                result[leftOpen[0]] = leftRemembered[0]
            }
        }
        return result
    }
}

enum LayoutGeometry {
    /// The display holding most of a window; for a window on none of them, the nearest.
    static func display(for frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard !displays.isEmpty else { return nil }
        func overlap(_ display: DisplayInfo) -> CGFloat {
            let i = display.frame.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = displays.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        func distance(_ display: DisplayInfo) -> CGFloat {
            hypot(display.frame.midX - center.x, display.frame.midY - center.y)
        }
        return displays.min(by: { distance($0) < distance($1) })
    }

    /// A window's frame as fractions of the display it is on.
    static func remember(frame: CGRect, bundleID: String, title: String, order: Int, displays: [DisplayInfo]) -> RememberedWindow? {
        guard frame.width > 0, frame.height > 0,
              let display = display(for: frame, in: displays),
              display.frame.width > 0, display.frame.height > 0 else { return nil }
        return RememberedWindow(
            bundleID: bundleID, title: String(title.prefix(LayoutStore.maxTitleLength)), order: order, display: display.id,
            x: Double((frame.minX - display.frame.minX) / display.frame.width),
            y: Double((frame.minY - display.frame.minY) / display.frame.height),
            width: Double(frame.width / display.frame.width),
            height: Double(frame.height / display.frame.height)
        )
    }

    /// Where a remembered window goes on the current displays, kept inside the display's
    /// visible area. Nil when that display is not connected.
    static func target(for window: RememberedWindow, displays: [DisplayInfo]) -> CGRect? {
        guard let display = displays.first(where: { $0.id == window.display }) else { return nil }
        let frame = display.frame
        let raw = CGRect(
            x: frame.minX + CGFloat(window.x) * frame.width,
            y: frame.minY + CGFloat(window.y) * frame.height,
            width: CGFloat(window.width) * frame.width,
            height: CGFloat(window.height) * frame.height
        )
        guard raw.width.isFinite, raw.height.isFinite, raw.minX.isFinite, raw.minY.isFinite,
              raw.width > 0, raw.height > 0 else { return nil }
        return clamp(raw.integral, into: display.visibleFrame)
    }

    /// Shrinks a frame that is larger than `visible`, then slides it fully inside.
    static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Converts a rectangle from AppKit's bottom-left space to the top-left space of
    /// Accessibility and CoreGraphics. `primaryHeight` is the primary display's height.
    static func topLeft(fromBottomLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Whether a window is already where it should be (within a couple of points).
    static func isInPlace(_ current: CGRect, _ target: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(current.minX - target.minX) <= tolerance && abs(current.minY - target.minY) <= tolerance
            && abs(current.width - target.width) <= tolerance && abs(current.height - target.height) <= tolerance
    }
}

enum LayoutMerge {
    /// What to store after a snapshot. Windows open and listed right now update their remembered
    /// entry (or add one); every other remembered entry stays, whether its window is minimized,
    /// full screen, on another Space, or its app is closed. Entries leave only through the cap,
    /// oldest-updated first.
    static func merged(existing: [RememberedWindow], current: [RememberedWindow], now: TimeInterval, limit: Int) -> [RememberedWindow] {
        let pairs = WindowMatcher.match(
            remembered: existing,
            open: current.map { OpenWindowRef(bundleID: $0.bundleID, title: $0.title, order: $0.order) }
        )
        var result = existing
        var added: [RememberedWindow] = []
        for (index, window) in current.enumerated() {
            var stamped = window
            stamped.updated = now
            if let slot = pairs[index] { result[slot] = stamped } else { added.append(stamped) }
        }
        result.append(contentsOf: added)
        guard result.count > limit else { return result }
        let keep = result.indices.sorted {
            result[$0].updated != result[$1].updated ? result[$0].updated > result[$1].updated : $0 < $1
        }.prefix(limit)
        return keep.sorted().map { result[$0] }
    }
}

/// Which on-screen windows have already been looked at in the current arrangement. A window
/// is placed from memory only the first time it is seen; after that, where it sits is the
/// user's business until the arrangement changes.
struct FirstSightTracker: Equatable {
    /// A window that is never ready (no title, not listed by Accessibility) is given up on after this many looks.
    static let maxLooks = 5
    private(set) var seen = Set<UInt32>()
    private var looks: [UInt32: Int] = [:]

    mutating func reset() {
        seen.removeAll()
        looks.removeAll()
    }

    /// Windows to look at now.
    func pending(visible: Set<UInt32>) -> Set<UInt32> { visible.subtracting(seen) }

    /// Marks windows as seen without placing them (the ones present when an arrangement settles).
    mutating func markSeen(_ ids: Set<UInt32>) { seen.formUnion(ids) }

    /// After a look: `settled` windows are done; `notReady` ones are looked at again, up to `maxLooks`.
    mutating func resolve(settled: Set<UInt32>, notReady: Set<UInt32>, visible: Set<UInt32>) {
        seen.formUnion(settled)
        for id in notReady {
            looks[id, default: 0] += 1
            if looks[id, default: 0] >= Self.maxLooks { seen.insert(id) }
        }
        // Windows that went away are forgotten, and window ids are not reused.
        if seen.count > 4000 { seen.formIntersection(visible) }
    }
}

/// Moves to make for one arrangement. Built for a key; applied only if the displays still form it.
struct LayoutPlan<Move> {
    let key: String
    let moves: [Move]

    /// The moves, or nil when the arrangement has changed since the plan was made.
    func validated(currentKey: String) -> [Move]? { currentKey == key ? moves : nil }
}

/// A burst of events is "quiet" once nothing has happened for `quiet` seconds; with a
/// `maxWait`, a source that never goes quiet is still acted on that long after its first event.
struct QuietPeriod: Equatable {
    let quiet: TimeInterval
    let maxWait: TimeInterval?
    private(set) var first: TimeInterval?
    private(set) var last: TimeInterval?

    init(quiet: TimeInterval, maxWait: TimeInterval? = nil) {
        self.quiet = quiet
        self.maxWait = maxWait
    }

    var isPending: Bool { first != nil }

    mutating func note(at now: TimeInterval) {
        if first == nil { first = now }
        last = now
    }

    func isDue(at now: TimeInterval) -> Bool {
        guard let first, let last else { return false }
        if now - last >= quiet { return true }
        if let maxWait, now - first >= maxWait { return true }
        return false
    }

    mutating func reset() {
        first = nil
        last = nil
    }
}

/// Decides when to restore and when to remember. Display changes win: while they are still
/// arriving, window movement (which the system causes itself) is not remembered.
struct LayoutScheduler: Equatable {
    enum Action: Equatable { case settleArrangement, saveLayout }

    /// Quiet needed after the last display change before restoring.
    static let arrangementQuiet: TimeInterval = 1.5
    /// Quiet needed after the last window movement before remembering, and the longest a
    /// window that keeps moving can delay it.
    static let movementQuiet: TimeInterval = 3
    static let movementMaxWait: TimeInterval = 30
    /// After a restore the system and apps may still shuffle windows; ignore that long.
    static let restoreHoldOff: TimeInterval = 5

    private(set) var arrangement = QuietPeriod(quiet: arrangementQuiet)
    private(set) var movement = QuietPeriod(quiet: movementQuiet, maxWait: movementMaxWait)
    private(set) var holdUntil: TimeInterval = 0

    mutating func displaysChanged(at now: TimeInterval) {
        arrangement.note(at: now)
        movement.reset()
    }

    mutating func windowsMoved(at now: TimeInterval) {
        guard !arrangement.isPending, now >= holdUntil else { return }
        movement.note(at: now)
    }

    mutating func due(at now: TimeInterval) -> Action? {
        if arrangement.isPending {
            guard arrangement.isDue(at: now) else { return nil }
            arrangement.reset()
            return .settleArrangement
        }
        if movement.isDue(at: now) {
            movement.reset()
            return .saveLayout
        }
        return nil
    }

    mutating func didRestore(at now: TimeInterval) {
        movement.reset()
        holdUntil = now + Self.restoreHoldOff
    }
}

enum WindowSignature {
    /// Changes when any window appears, disappears, moves or resizes.
    static func of(_ windows: [(id: UInt32, frame: CGRect)]) -> Int {
        var hasher = Hasher()
        for window in windows.sorted(by: { $0.id < $1.id }) {
            hasher.combine(window.id)
            hasher.combine(Int(window.frame.minX.rounded()))
            hasher.combine(Int(window.frame.minY.rounded()))
            hasher.combine(Int(window.frame.width.rounded()))
            hasher.combine(Int(window.frame.height.rounded()))
        }
        return hasher.finalize()
    }
}
