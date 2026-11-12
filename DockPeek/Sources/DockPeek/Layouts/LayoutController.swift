import Cocoa
import ApplicationServices

/// Remembers where windows are for each monitor arrangement and puts them back when the
/// arrangement returns. It installs no event tap or hot key: a once-a-second timer reads one
/// cheap window-server fingerprint, and a screen-change notification starts the settle timer.
/// Both exist only while automatic restoring is on; the two manual commands always work.
final class LayoutController {
    private let file: LayoutStoreFile
    private let queue = DispatchQueue(label: "com.andrew.dockpeek.layouts", qos: .utility)
    private var scheduler = LayoutScheduler()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var currentArrangement: String?
    private var lastSignature: Int?
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
            let changed = key != currentArrangement
            currentArrangement = key
            if changed { restore(displays: displays, key: key, announce: false) }
            scheduler.didRestore(at: now)
        case .saveLayout:
            let displays = LayoutSystem.displays()
            let key = Arrangement.key(for: displays)
            // Displays changed without a notification reaching us yet: wait for them to settle.
            guard key == currentArrangement else {
                scheduler.displaysChanged(at: now)
                return
            }
            save(displays: displays, key: key, announce: false)
        case nil:
            break
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
        queue.async { [file] in file.forget() }
        report("Forgot Saved Layouts")
    }

    // MARK: - Work

    private func save(displays: [DisplayInfo], key: String, announce: Bool) {
        let apps = LayoutSystem.runningApps()
        queue.async { [file, weak self] in
            let live = LayoutSystem.liveWindows(apps: apps)
            let current = live.windows.compactMap {
                LayoutGeometry.remember(frame: $0.frame, bundleID: $0.bundleID, title: $0.title, order: $0.order, displays: displays)
            }
            var store = file.load()
            let existing = store.record(for: key)?.windows ?? []
            let merged = LayoutMerge.merged(
                existing: existing, current: current, readableBundles: live.readable, limit: LayoutStore.maxWindowsPerArrangement
            )
            // Apps that could not be read keep their remembered windows (see LayoutMerge).
            store.set(merged, for: key, now: Date())
            let written = file.save(store)
            if announce { self?.report(!written ? "Couldn’t Save Layout" : "Saved \(current.count) \(current.count == 1 ? "Window" : "Windows")") }
        }
    }

    private func restore(displays: [DisplayInfo], key: String, announce: Bool) {
        let apps = LayoutSystem.runningApps()
        queue.async { [file, weak self] in
            var store = file.load()
            guard let record = store.record(for: key), !record.windows.isEmpty else {
                if announce { self?.report("No Saved Layout") }
                return
            }
            let live = LayoutSystem.liveWindows(apps: apps)
            let pairs = WindowMatcher.match(
                remembered: record.windows,
                open: live.windows.map { OpenWindowRef(bundleID: $0.bundleID, title: $0.title, order: $0.order) }
            )
            var moved = 0
            for (openIndex, rememberedIndex) in pairs {
                let window = live.windows[openIndex]
                guard let target = LayoutGeometry.target(for: record.windows[rememberedIndex], displays: displays),
                      !LayoutGeometry.isInPlace(window.frame, target) else { continue }
                if LayoutSystem.setFrame(window.element, to: target) { moved += 1 }
            }
            store.touch(key, now: Date())
            file.save(store)
            if announce { self?.report("Restored \(moved) \(moved == 1 ? "Window" : "Windows")") }
        }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onResult?(text) }
    }
}
