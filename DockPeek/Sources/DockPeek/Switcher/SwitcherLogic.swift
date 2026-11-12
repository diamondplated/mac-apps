import Foundation
import CoreGraphics

// Pure decisions for the ⌥Tab window switcher. Nothing here touches the window
// server, Accessibility or the screen, so every rule is unit tested.

/// One window as the window server lists it, front to back.
struct SwitcherServerWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// Only available with Screen Recording access.
    let title: String?
    let bounds: CGRect
    let isOnScreen: Bool
}

/// One window as its app reports it through Accessibility.
struct SwitcherAXWindow: Equatable {
    /// Zero when the app's element does not map to a window-server window.
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let subrole: String
    let bounds: CGRect
    let isMinimized: Bool
}

/// A window the switcher shows, in the order it shows them.
struct SwitcherCandidate: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let isMinimized: Bool
    /// Index into the app's Accessibility windows, when the app reported this window.
    let axIndex: Int?
}

enum SwitcherOrdering {
    /// Front-to-back order across every app, minimized windows last.
    ///
    /// - The window server's order is the recency order; Accessibility is the
    ///   ground truth for which surfaces are real windows (as in the Dock preview).
    /// - An on-screen surface that an app's Accessibility list omits is a helper
    ///   surface and is skipped. An off-screen one is usually on another Space,
    ///   where Accessibility cannot see it; it is kept only when it has a title.
    /// - `axApps` holds the apps whose Accessibility windows could be read.
    static func order(
        serverWindows: [SwitcherServerWindow],
        axWindows: [pid_t: [SwitcherAXWindow]],
        axApps: Set<pid_t>,
        excluding excludedPID: pid_t? = nil
    ) -> [SwitcherCandidate] {
        var placed = Set<CGWindowID>()
        var visible: [SwitcherCandidate] = []
        var minimized: [SwitcherCandidate] = []

        func place(_ candidate: SwitcherCandidate) {
            guard candidate.id == 0 || !placed.contains(candidate.id) else { return }
            if candidate.id != 0 { placed.insert(candidate.id) }
            if candidate.isMinimized { minimized.append(candidate) } else { visible.append(candidate) }
        }

        var axIndexByID: [CGWindowID: (window: SwitcherAXWindow, index: Int)] = [:]
        for (_, windows) in axWindows {
            for (index, window) in windows.enumerated() where window.id != 0 {
                axIndexByID[window.id] = (window, index)
            }
        }

        for server in serverWindows where server.pid != excludedPID {
            if let match = axIndexByID[server.id], match.window.pid == server.pid {
                let ax = match.window
                guard WindowFilter.includes(title: ax.title, subrole: ax.subrole, bounds: ax.bounds, isMinimized: ax.isMinimized) else { continue }
                place(SwitcherCandidate(id: server.id, pid: server.pid, title: ax.title, isMinimized: ax.isMinimized, axIndex: match.index))
                continue
            }
            if axApps.contains(server.pid) && server.isOnScreen { continue }
            let title = server.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, server.bounds.width >= 100, server.bounds.height >= 80 else { continue }
            place(SwitcherCandidate(id: server.id, pid: server.pid, title: title, isMinimized: false, axIndex: nil))
        }

        // Minimized windows the window server did not list (or listed under no id).
        for pid in axWindows.keys.sorted() where pid != excludedPID {
            for (index, ax) in (axWindows[pid] ?? []).enumerated() where ax.isMinimized {
                guard ax.id == 0 || !placed.contains(ax.id),
                      WindowFilter.includes(title: ax.title, subrole: ax.subrole, bounds: ax.bounds, isMinimized: true) else { continue }
                place(SwitcherCandidate(id: ax.id, pid: pid, title: ax.title, isMinimized: true, axIndex: index))
            }
        }
        return visible + minimized
    }

    /// The window the user is in now, when the first window belongs to the frontmost app.
    /// The switcher's first step lands on the window after it: the one used just before.
    static func currentIndex(of windows: [SwitcherCandidate], frontmostPID: pid_t?) -> Int? {
        guard let first = windows.first, !first.isMinimized, first.pid == frontmostPID else { return nil }
        return 0
    }
}

enum SwitcherSelection {
    /// Moves the highlight with wrap-around. From no highlight (`nil`), forward lands
    /// on the first window and backward on the last.
    static func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else {
            if delta == 0 { return 0 }
            let start = delta > 0 ? delta - 1 : count + delta
            return ((start % count) + count) % count
        }
        return (((index + delta) % count) + count) % count
    }

    /// Up and down move a whole row, staying in the same column and not wrapping.
    static func row(from index: Int, by rows: Int, columns: Int, count: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let target = index + rows * columns
        guard target >= 0, target < count else {
            // Moving down from a short last row lands on the last window.
            if rows > 0, (index / columns) < ((count - 1) / columns) { return count - 1 }
            return index
        }
        return target
    }
}

/// One ⌥Tab press-to-release, independent of timers and the window server.
struct SwitcherSession {
    enum Phase: Equatable { case loading, ready, shown, finished }

    private(set) var phase: Phase = .loading
    private(set) var highlight: Int?
    private(set) var count = 0
    private var pendingSteps = 0
    private var releasedBeforeLoad = false
    private var delayElapsedWhileLoading = false

    /// Starts with the first Tab (or ⇧Tab) already applied.
    init(forward: Bool) {
        pendingSteps = forward ? 1 : -1
    }

    enum LoadOutcome: Equatable {
        /// ⌥ is still held: wait for the show delay or more keys.
        case wait
        /// ⌥ is still held and the show delay already ran out: show the panel now.
        case show
        /// ⌥ was already released: switch to this window (nil when there is none)
        /// without the panel ever appearing.
        case switchNow(Int?)
    }

    /// The window list arrived.
    mutating func load(count: Int, currentIndex: Int?) -> LoadOutcome {
        guard phase == .loading else { return .wait }
        self.count = count
        highlight = SwitcherSelection.step(from: currentIndex, by: pendingSteps, count: count)
            ?? (count > 0 ? 0 : nil)
        pendingSteps = 0
        if releasedBeforeLoad {
            phase = .finished
            return .switchNow(highlight)
        }
        phase = .ready
        if delayElapsedWhileLoading, count > 0 {
            phase = .shown
            return .show
        }
        return .wait
    }

    mutating func move(by delta: Int) {
        switch phase {
        case .loading: pendingSteps += delta
        case .ready, .shown: highlight = SwitcherSelection.step(from: highlight, by: delta, count: count)
        case .finished: break
        }
    }

    mutating func moveRow(by rows: Int, columns: Int) {
        guard phase == .ready || phase == .shown, let highlight else { return }
        self.highlight = SwitcherSelection.row(from: highlight, by: rows, columns: columns, count: count)
    }

    mutating func select(_ index: Int) {
        guard phase == .ready || phase == .shown, index >= 0, index < count else { return }
        highlight = index
    }

    /// The show delay ran out. True when the panel should appear now.
    mutating func showDelayElapsed() -> Bool {
        if phase == .loading { delayElapsedWhileLoading = true }
        guard phase == .ready, count > 0 else { return false }
        phase = .shown
        return true
    }

    /// ⌥ released. Returns the window to raise, or nil to wait for the list.
    mutating func commit() -> Int? {
        switch phase {
        case .loading:
            releasedBeforeLoad = true
            return nil
        case .ready, .shown:
            phase = .finished
            return highlight
        case .finished:
            return nil
        }
    }

    mutating func cancel() { phase = .finished }

    var wasShown: Bool { phase == .shown }
}

/// What the key tap does with one keyboard event. Runs on the tap's thread.
struct SwitcherKeyRouter {
    enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    enum Action: Equatable {
        case begin(forward: Bool)
        case step(Int)
        case row(Int)
        case commit
        case cancel
    }

    enum Kind { case keyDown, keyUp, flagsChanged }

    struct Decision: Equatable {
        let consume: Bool
        let action: Action?
        static let pass = Decision(consume: false, action: nil)
    }

    private(set) var isActive = false
    private var swallowedKeyUps = Set<Int64>()

    /// Option is held with neither Command nor Control: ⌘⌥Tab and ⌃⌥Tab stay the apps'.
    private static func optionOnly(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
    }

    mutating func handle(kind: Kind, keyCode: Int64, flags: CGEventFlags) -> Decision {
        switch kind {
        case .flagsChanged:
            // Modifier changes always reach the apps so their modifier state stays right.
            guard isActive, !flags.contains(.maskAlternate) else { return .pass }
            isActive = false
            return Decision(consume: false, action: .commit)
        case .keyUp:
            guard swallowedKeyUps.remove(keyCode) != nil else { return .pass }
            return Decision(consume: true, action: nil)
        case .keyDown:
            let shift = flags.contains(.maskShift)
            if !isActive {
                guard keyCode == Key.tab, Self.optionOnly(flags) else { return .pass }
                isActive = true
                // Key-ups missed while the tap was disabled must not linger into this session.
                swallowedKeyUps.removeAll()
                return swallow(keyCode, .begin(forward: !shift))
            }
            guard flags.contains(.maskAlternate) else {
                // Option was released without us seeing it: finish rather than trap keys.
                isActive = false
                return Decision(consume: false, action: .commit)
            }
            switch keyCode {
            case Key.tab: return swallow(keyCode, .step(shift ? -1 : 1))
            case Key.right: return swallow(keyCode, .step(1))
            case Key.left: return swallow(keyCode, .step(-1))
            case Key.down: return swallow(keyCode, .row(1))
            case Key.up: return swallow(keyCode, .row(-1))
            case Key.escape:
                isActive = false
                return swallow(keyCode, .cancel)
            case Key.returnKey, Key.keypadEnter:
                isActive = false
                return swallow(keyCode, .commit)
            default: return .pass
            }
        }
    }

    /// The panel finished another way (a click, or the app lost its permission).
    mutating func reset() {
        isActive = false
        swallowedKeyUps.removeAll()
    }

    private mutating func swallow(_ keyCode: Int64, _ action: Action) -> Decision {
        swallowedKeyUps.insert(keyCode)
        return Decision(consume: true, action: action)
    }
}

/// Card grid geometry for the switcher panel.
struct SwitcherLayout: Equatable {
    static let thumbnailSize = CGSize(width: 210, height: 132)
    static let cardPadding: CGFloat = 6
    static let titleHeight: CGFloat = 20
    static let spacing: CGFloat = 12
    static let inset: CGFloat = 14
    static var cardSize: CGSize {
        CGSize(
            width: thumbnailSize.width + cardPadding * 2,
            height: cardPadding + thumbnailSize.height + 6 + titleHeight + cardPadding
        )
    }

    let columns: Int
    let rows: Int
    let size: CGSize
    let scrolls: Bool

    init(count: Int, availableSize: CGSize) {
        let card = Self.cardSize
        let fit = Int((availableSize.width - Self.inset * 2 + Self.spacing) / (card.width + Self.spacing))
        columns = max(1, min(max(count, 1), fit))
        rows = max(1, Int((Double(max(count, 1)) / Double(columns)).rounded(.up)))
        let width = CGFloat(columns) * card.width + CGFloat(columns - 1) * Self.spacing + Self.inset * 2
        let height = CGFloat(rows) * card.height + CGFloat(rows - 1) * Self.spacing + Self.inset * 2
        scrolls = height > availableSize.height
        size = CGSize(width: min(width, availableSize.width), height: min(height, availableSize.height))
    }
}
