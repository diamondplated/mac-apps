import Cocoa
import ApplicationServices

/// Remembers where windows are for each monitor arrangement and puts them back when the
/// arrangement returns. It installs no event tap or hot key: a once-a-second timer reads one
/// cheap window-server fingerprint, and a screen-change notification starts the settle timer.
/// Both exist only while automatic restoring is on; the manual commands always work.
final class LayoutController {
    private struct Move {
        let element: AXUIElement
        let target: CGRect
    }

    private let file: LayoutStoreFile
    private let queue = DispatchQueue(label: "com.andrew.dockpeek.layouts", qos: .utility)
    private var scheduler = LayoutScheduler()
    private var tracker = FirstSightTracker()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var currentArrangement: String?
    private var lastSignature: Int?
    private var lookInFlight = false
    private var accessibilityGranted = false

    /// Told, on the main thread, what a command did ("Saved 12 Windows").
    var onResult: ((String) -> Void)?

    init(file: LayoutStoreFile = LayoutStoreFile(url: LayoutStoreFile.defaultURL)) {
        self.file = file
    }

    deinit { stopAutomatic() }

    // MARK: - Automatic

    var isAutomatic: Bool { timer != nil }

    func apply(automatic: Bool, accessibilityGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        guard automatic && accessibilityGranted else { return stopAutomatic() }
        guard timer == nil else { return }
        scheduler = LayoutScheduler()
        tracker.reset()
        lookInFlight = false
        currentArrangement = nil
        lastSignature = LayoutSystem.onScreenSignature()
        // Treat starting like an arrangement change: wait for quiet, then restore what is remembered.
        scheduler.displaysChanged(at: ProcessInfo.processInfo.systemUptime)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduler.displaysChanged(at: ProcessInfo.processInfo.systemUptime)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAutomatic() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let signature = LayoutSystem.onScreenSignature()
        if signature != lastSignature {
            lastSignature = signature
            scheduler.windowsMoved(at: now)
        }
        switch scheduler.due(at: now) {
        case .settleArrangement:
            let displays = LayoutSystem.displays()
            let key = Arrangement.key(for: displays)
            if key != currentArrangement {
                currentArrangement = key
                tracker.reset()
                restore(displays: displays, key: key, announce: false)
            }
            // Windows already open now were handled by the restore; later ones are placed as they appear.
            tracker.markSeen(LayoutSystem.visibleWindowIDs())
            scheduler.didRestore(at: now)
        case .saveLayout:
            let displays = LayoutSystem.displays()
            let key = Arrangement.key(for: displays)
            // Displays changed without a notification reaching us yet: wait for them to settle.
            guard key == currentArrangement else {
                scheduler.displaysChanged(at: now)
                return
            }
            // A window that has just appeared is about to be placed; do not record its default spot first.
            if lookInFlight || !tracker.pending(visible: LayoutSystem.visibleWindowIDs()).isEmpty {
                scheduler.windowsMoved(at: now)
                return
            }
            save(displays: displays, key: key, announce: false)
        case nil:
            if !scheduler.arrangement.isPending { placeNewWindows() }
        }
    }

    // MARK: - Commands

    func saveNow() {
        guard accessibilityGranted || AXIsProcessTrusted() else { return report("Needs Accessibility") }
        let displays = LayoutSystem.displays()
        save(displays: displays, key: Arrangement.key(for: displays), announce: true)
    }

    func restoreNow() {
        guard accessibilityGranted || AXIsProcessTrusted() else { return report("Needs Accessibility") }
        let displays = LayoutSystem.displays()
        restore(displays: displays, key: Arrangement.key(for: displays), announce: true)
    }

    func forgetAll() {
        queue.async { [file] in
            file.forget()
            try? FileManager.default.removeItem(at: file.url.appendingPathExtension("unreadable"))
        }
        report("Forgot Saved Layouts")
    }

    // MARK: - Work

    /// Reads the open windows, then (on the main thread) checks the displays still form `key`
    /// before writing, so nothing is filed under the wrong arrangement.
    private func save(displays: [DisplayInfo], key: String, announce: Bool) {
        let apps = LayoutSystem.runningApps()
        queue.async { [weak self] in
            let live = LayoutSystem.liveWindows(apps: apps)
            let current = live.windows.compactMap {
                LayoutGeometry.remember(frame: $0.frame, bundleID: $0.bundleID, title: $0.title, order: $0.order, displays: displays)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard Arrangement.key(for: LayoutSystem.displays()) == key else {
                    if self.isAutomatic { self.scheduler.displaysChanged(at: ProcessInfo.processInfo.systemUptime) }
                    if announce { self.report("Displays Changed") }
                    return
                }
                self.queue.async { [file = self.file] in
                    var store = file.load()
                    let existing = store.record(for: key)?.windows ?? []
                    let now = Date()
                    let merged = LayoutMerge.merged(
                        existing: existing, current: current, now: now.timeIntervalSince1970, limit: LayoutStore.maxWindowsPerArrangement
                    )
                    store.set(merged, for: key, now: now)
                    let written = file.save(store)
                    if announce { self.report(written ? "Saved \(current.count) \(current.count == 1 ? "Window" : "Windows")" : "Couldn’t Save Layout") }
                }
            }
        }
    }

    private func restore(displays: [DisplayInfo], key: String, announce: Bool) {
        let apps = LayoutSystem.runningApps()
        queue.async { [weak self] in
            guard let self else { return }
            var store = self.file.load()
            guard let record = store.record(for: key), !record.windows.isEmpty else {
                if announce { self.report("No Saved Layout") }
                return
            }
            let live = LayoutSystem.liveWindows(apps: apps)
            let pairs = WindowMatcher.match(
                remembered: record.windows,
                open: live.windows.map { OpenWindowRef(bundleID: $0.bundleID, title: $0.title, order: $0.order) }
            )
            var moves: [Move] = []
            for (openIndex, rememberedIndex) in pairs {
                let window = live.windows[openIndex]
                guard let target = LayoutGeometry.target(for: record.windows[rememberedIndex], displays: displays),
                      !LayoutGeometry.isInPlace(window.frame, target) else { continue }
                moves.append(Move(element: window.element, target: target))
            }
            store.touch(key, now: Date())
            self.file.save(store)
            DispatchQueue.main.async { self.apply(LayoutPlan(key: key, moves: moves), announce: announce) }
        }
    }

    /// Windows that appear after the arrangement settled (login, a relaunch) get their remembered
    /// place once, the first time they are seen. Never moves a window that was seen before.
    private func placeNewWindows() {
        guard let key = currentArrangement, !lookInFlight else { return }
        let visible = LayoutSystem.visibleWindowIDs()
        let pending = tracker.pending(visible: visible)
        guard !pending.isEmpty else { return }
        let displays = LayoutSystem.displays()
        guard Arrangement.key(for: displays) == key else {
            scheduler.displaysChanged(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        lookInFlight = true
        let apps = LayoutSystem.runningApps()
        queue.async { [weak self] in
            guard let self else { return }
            var settled = pending
            var notReady = Set<UInt32>()
            var moves: [Move] = []
            if let record = self.file.load().record(for: key), !record.windows.isEmpty {
                let live = LayoutSystem.liveWindows(apps: apps).windows
                // A new window is ready once Accessibility lists it with a title.
                let titled = Set(live.filter { !$0.title.isEmpty && $0.id != 0 }.map(\.id))
                notReady = pending.subtracting(titled)
                settled = pending.subtracting(notReady)
                let candidates = live.filter { !(pending.contains($0.id) && $0.title.isEmpty) }
                let pairs = WindowMatcher.match(
                    remembered: record.windows,
                    open: candidates.map { OpenWindowRef(bundleID: $0.bundleID, title: $0.title, order: $0.order) }
                )
                for (index, rememberedIndex) in pairs {
                    let window = candidates[index]
                    guard settled.contains(window.id),
                          let target = LayoutGeometry.target(for: record.windows[rememberedIndex], displays: displays),
                          !LayoutGeometry.isInPlace(window.frame, target) else { continue }
                    moves.append(Move(element: window.element, target: target))
                }
            }
            DispatchQueue.main.async {
                self.lookInFlight = false
                guard self.isAutomatic, self.currentArrangement == key else { return }
                self.tracker.resolve(settled: settled, notReady: notReady, visible: visible)
                self.apply(LayoutPlan(key: key, moves: moves), announce: false)
            }
        }
    }

    /// Applies a plan only if the displays still form the arrangement it was built for;
    /// otherwise drops it and lets the settle logic run again.
    private func apply(_ plan: LayoutPlan<Move>, announce: Bool) {
        let current = Arrangement.key(for: LayoutSystem.displays())
        guard let moves = plan.validated(currentKey: current) else {
            if isAutomatic { scheduler.displaysChanged(at: ProcessInfo.processInfo.systemUptime) }
            if announce { report("Displays Changed") }
            return
        }
        guard !moves.isEmpty else {
            if announce { report("Restored 0 Windows") }
            return
        }
        queue.async { [weak self] in
            var moved = 0
            for move in moves where LayoutSystem.setFrame(move.element, to: move.target) { moved += 1 }
            if announce { self?.report("Restored \(moved) \(moved == 1 ? "Window" : "Windows")") }
        }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onResult?(text) }
    }
}
