import Cocoa
import ApplicationServices

/// ⌥Tab: owns the key tap (installed only while the switcher is on), the session and the panel.
final class SwitcherController {
    /// A quick ⌥Tab released within this time switches without showing the panel.
    static let showDelay: TimeInterval = 0.15

    private let panel = SwitcherPanel()
    private let model = SwitcherModel()
    private let windowService = WindowService.shared
    private var tap: EventTap?
    private var session: SwitcherSession?
    private var sessionID = UUID()
    private var captureTask: Task<Void, Never>?
    private var modifierWatch: Timer?
    private var capturesThumbnails = false
    /// A session whose ⌥ was released before its window list arrived. It still switches
    /// when the list arrives, even if a new ⌥Tab has started in the meantime.
    private var deferred: (id: UUID, session: SwitcherSession)?

    private let routerLock = NSLock()
    private var router = SwitcherKeyRouter()

    deinit { stop() }

    func apply(enabled: Bool, accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        capturesThumbnails = screenRecordingGranted
        guard enabled && accessibilityGranted else { return stop() }
        guard tap == nil else { return }
        let tap = EventTap(events: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
            self?.handle(type, event) ?? false
        }
        if tap.start() { self.tap = tap }
    }

    func stop() {
        tap?.stop()
        tap = nil
        finish()
    }

    // MARK: - Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let kind: SwitcherKeyRouter.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return false
        }
        routerLock.lock()
        let decision = router.handle(kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        routerLock.unlock()
        if let action = decision.action {
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
        return decision.consume
    }

    private func resetRouter() {
        routerLock.lock()
        router.reset()
        routerLock.unlock()
    }

    // MARK: - Main thread

    private func perform(_ action: SwitcherKeyRouter.Action) {
        switch action {
        case .begin(let forward): begin(forward: forward)
        case .step(let delta):
            session?.move(by: delta)
            publishHighlight()
        case .row(let rows):
            session?.moveRow(by: rows, columns: model.columns)
            publishHighlight()
        case .commit: commit()
        case .cancel: finish()
        }
    }

    private func begin(forward: Bool) {
        // The router has just started this session; keep it active.
        finish(resettingRouter: false)
        let id = UUID()
        sessionID = id
        session = SwitcherSession(forward: forward)
        watchModifier()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
            guard let self, self.sessionID == id, self.session?.showDelayElapsed() == true else { return }
            self.showPanel()
        }

        Task { @MainActor [weak self] in
            let entries = await SwitcherWindowSource.load()
            guard let self, self.sessionID == id || self.deferred?.id == id else { return }
            await self.loaded(entries, sessionID: id)
        }
    }

    @MainActor
    private func loaded(_ entries: [SwitcherEntry], sessionID id: UUID) async {
        if let deferred, deferred.id == id {
            self.deferred = nil
            var session = deferred.session
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let current = SwitcherOrdering.currentIndex(of: entries.map(\.candidate), frontmostPID: frontmost)
            if case .switchNow(let index?) = session.load(count: entries.count, currentIndex: current) {
                raise(entries[index])
            }
            if sessionID == id { finish() }
            return
        }
        // Cached thumbnails go in before the panel can appear; fresh ones follow.
        var cached: [CGWindowID: NSImage] = [:]
        for entry in entries where entry.candidate.id != 0 {
            if let image = await windowService.cachedThumbnail(for: entry.candidate.id) { cached[entry.candidate.id] = image }
        }
        guard sessionID == id, var session else { return }
        model.entries = entries
        model.thumbnails = cached
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let outcome = session.load(count: entries.count, currentIndex: SwitcherOrdering.currentIndex(of: entries.map(\.candidate), frontmostPID: frontmost))
        self.session = session
        publishHighlight()
        switch outcome {
        case .wait: break
        case .show: showPanel()
        case .switchNow(let index):
            if let index { raise(entries[index]) }
            finish()
            return
        }
        guard capturesThumbnails else { return }
        let ids = entries.filter { !$0.candidate.isMinimized && $0.candidate.id != 0 }.map(\.candidate.id)
        captureTask = Task { [weak self, windowService] in
            await windowService.captureThumbnails(for: ids) { windowID, image in
                guard let self, self.sessionID == id else { return }
                self.model.thumbnails[windowID] = image
            }
        }
    }

    private func showPanel() {
        panel.show(model: model) { [weak self] index in self?.select(index) }
    }

    private func publishHighlight() {
        if model.highlight != session?.highlight { model.highlight = session?.highlight }
    }

    private func select(_ index: Int) {
        session?.select(index)
        resetRouter()
        commit()
    }

    private func commit() {
        guard var session else { return }
        let index = session.commit()
        self.session = session
        // Still loading: the load raises the highlighted window when it arrives.
        guard session.phase == .finished else {
            deferred = (sessionID, session)
            return
        }
        if let index, model.entries.indices.contains(index) { raise(model.entries[index]) }
        finish()
    }

    private func raise(_ entry: SwitcherEntry) {
        if entry.axElement != nil {
            windowService.raiseWindow(entry.windowInfo)
        } else if let app = NSRunningApplication(processIdentifier: entry.candidate.pid) {
            // A window on another Space: bringing its app forward takes the user there.
            windowService.activate(app)
        }
    }

    /// Ends the session and hides the panel. Safe to call at any time.
    private func finish(resettingRouter: Bool = true) {
        sessionID = UUID()
        session = nil
        captureTask?.cancel()
        captureTask = nil
        modifierWatch?.invalidate()
        modifierWatch = nil
        if resettingRouter { resetRouter() }
        panel.hide()
        // Let go of the images and window elements once the panel has faded out.
        let ended = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.sessionID == ended else { return }
            self.model.entries = []
            self.model.thumbnails = [:]
            self.model.highlight = nil
        }
    }

    /// Backs up the tap: if ⌥ is released while the tap was briefly disabled, the
    /// release still ends the session instead of leaving the panel up.
    private func watchModifier() {
        modifierWatch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.session != nil else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
                self.resetRouter()
                self.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierWatch = timer
    }
}
