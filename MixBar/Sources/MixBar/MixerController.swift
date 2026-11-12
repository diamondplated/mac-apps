import AppKit
import MixBarCore

/// Joins the real audio system, the engine, the saved settings and the mixer view.
@MainActor
final class MixerController {
    let preferences = Preferences()
    let audio = CoreAudioSystem()
    let engine: MixerEngine
    let viewModel = MixerViewModel()
    private(set) var settings = MixBarSettings()
    /// Mixer choices while remembering is off; they last until the app quits.
    private var session: [String: AppVolume] = [:]
    private var snapshot = AudioSnapshot(groups: [], outputs: [], defaultOutputUID: nil)
    private var runningApps: [RunningApp] = []
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var reconcileWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var failedHandles = Set<TapHandle>()
    /// Between sleep and wake: no taps, and device changes do not create any.
    private var asleep = false
    /// Mac Tools changed settings while our own save was pending; re-read after it.
    private var reloadAfterSave = false
    var mixerOpen = false { didSet { if mixerOpen { engine.clearFailures(); refresh() } } }

    init() {
        let learned = UserDefaults.standard.string(forKey: Preferences.learnedCaptureStatusKey).flatMap(CaptureStatus.init(rawValue:)) ?? .unknown
        engine = MixerEngine(service: audio, captureStatus: learned)
        engine.onCaptureStatusChange = { [weak self] status in
            UserDefaults.standard.set(status.rawValue, forKey: Preferences.learnedCaptureStatusKey)
            self?.viewModel.captureStatus = status
        }
        viewModel.captureStatus = learned
        viewModel.available = audio.tapsAvailable
        settings = preferences.settings
        audio.onChange = { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        audio.onServiceRestart = { [weak self] in MainActor.assumeIsolated { self?.serviceRestarted() } }
        audio.onTapFailure = { [weak self] handle in MainActor.assumeIsolated { self?.tapFailed(handle) } }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.engine.removeAll()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    self?.asleep = false
                    self?.rebuildAll()
                }
            }
        })
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Preferences.statusRequest, object: Preferences.identifier, queue: .main) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                center.postNotificationName(Preferences.statusReply, object: token,
                                            userInfo: ["pid": ProcessInfo.processInfo.processIdentifier, "audioCaptureStatus": self.engine.captureStatus.rawValue],
                                            deliverImmediately: true)
            }
        })
        observers.append(center.addObserver(forName: Preferences.changed, object: Preferences.identifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        wireViewModel()
    }

    func start() {
        guard audio.tapsAvailable else { updateViewModel(); return }
        audio.startListening()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Quitting removes every tap, so every app plays as if MixBar had never run.
    func stop() {
        poll?.invalidate()
        saveWork?.perform()
        engine.removeAll()
        audio.stopListening()
    }

    var hasNonNeutralSettings: Bool {
        (settings.remembersVolumes ? settings.appVolumes : Array(session.values)).contains { !$0.isNeutral }
    }

    /// Settings changed in Mac Tools.
    func reload() {
        guard saveWork == nil else { reloadAfterSave = true; return }  // our own pending save is newer
        settings = preferences.settings
        if settings.remembersVolumes { session.removeAll() }
        refresh()
    }

    private func effective(_ bundleIdentifier: String) -> AppVolume? {
        SettingResolver.effective(bundleIdentifier, settings: settings, session: session)
    }

    // MARK: Reading the audio system

    private func tick() {
        // Nothing to watch: no taps, no settings to apply, mixer closed.
        guard mixerOpen || !engine.live.isEmpty || hasNonNeutralSettings else { return }
        refresh()
    }

    func refresh() {
        guard audio.tapsAvailable else { updateViewModel(); return }
        guard !asleep else { return }
        let now = Date()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let identifier = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleIdentifier: identifier, name: app.localizedName ?? identifier, bundlePath: app.bundleURL?.path)
        }
        let groups = AppGrouping.group(audio.processes(), apps: runningApps, excludingPID: ProcessInfo.processInfo.processIdentifier,
                                       excludingBundleIdentifier: Preferences.identifier)
        snapshot = AudioSnapshot(groups: groups, outputs: audio.outputDevices(), defaultOutputUID: audio.defaultOutputUID())
        session = MixerEditing.pruneSession(session, runningBundleIdentifiers: Set(runningApps.map(\.bundleIdentifier)))
        engine.checkHealth(snapshot, now: now)
        engine.reconcile(snapshot, settings: effective, now: now)
        if mixerOpen { updateViewModel() }
    }

    private func rebuildAll() {
        refresh()
        engine.rebuildAll(snapshot, settings: effective, now: Date())
    }

    private func serviceRestarted() {
        engine.removeAll()
        audio.stopListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audio.startListening()
                self.rebuildAll()
            }
        }
    }

    /// Several properties change together when a device goes away; handle the burst once.
    private func tapFailed(_ handle: TapHandle) {
        guard failedHandles.insert(handle).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let handles = self.failedHandles
                self.failedHandles.removeAll()
                let now = Date()
                for (bundle, tap) in self.engine.live where handles.contains(tap.handle) { self.engine.tapFailed(bundle, now: now) }
                self.refresh()
            }
        }
    }

    // MARK: Mixer

    private func wireViewModel() {
        viewModel.setVolume = { [weak self] bundle, volume in MainActor.assumeIsolated { self?.edit(bundle) { $0.volume = volume } } }
        viewModel.toggleMute = { [weak self] bundle in MainActor.assumeIsolated { self?.edit(bundle) { $0.muted.toggle() } } }
        viewModel.setOutput = { [weak self] bundle, uid in MainActor.assumeIsolated { self?.edit(bundle) { $0.outputDeviceUID = uid } } }
        viewModel.setSystemVolume = { [weak self] volume in
            MainActor.assumeIsolated {
                self?.audio.setSystemVolume(volume)
                self?.viewModel.systemOutput?.volume = volume
            }
        }
    }

    private func name(of bundleIdentifier: String) -> String? {
        snapshot.group(bundleIdentifier)?.name ?? runningApps.first { $0.bundleIdentifier == bundleIdentifier }?.name
    }

    private func edit(_ bundleIdentifier: String, _ change: (inout AppVolume) -> Void) {
        var entry = effective(bundleIdentifier) ?? AppVolume(bundleIdentifier: bundleIdentifier, name: name(of: bundleIdentifier) ?? bundleIdentifier)
        change(&entry)
        entry.volume = min(max(entry.volume, AppVolume.range.lowerBound), AppVolume.range.upperBound)
        if settings.remembersVolumes {
            settings.appVolumes = MixerEditing.updating(settings.appVolumes, with: entry)
            scheduleSave()
        } else {
            session[bundleIdentifier] = entry.isNeutral ? nil : entry
        }
        // Gain moves at once; creating or removing a tap waits for the drag to settle.
        engine.updateGains(settings: effective)
        scheduleReconcile()
        updateViewModel()
    }

    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveWork = nil
                let list = self.settings.appVolumes
                do {
                    try self.preferences.apply(SettingsPatch(data: SettingsPatch.data(appVolumes: list))) { identifier in
                        self.name(of: identifier) ?? Preferences.installedName(identifier)
                    }
                } catch { NSLog("MixBar could not save app volumes: \(error.localizedDescription)") }
                if self.reloadAfterSave {
                    self.reloadAfterSave = false
                    self.reload()
                }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func updateViewModel() {
        viewModel.available = audio.tapsAvailable
        guard audio.tapsAvailable else { viewModel.rows = []; viewModel.systemOutput = nil; return }
        let regular = runningApps.filter { app in
            NSRunningApplication(processIdentifier: app.pid)?.activationPolicy == .regular
        }
        let entries = MixerEditing.rows(snapshot: snapshot, liveBundles: Set(engine.live.keys), runningApps: regular, setting: effective)
        viewModel.rows = entries.map { entry in
            MixerViewModel.Row(bundleIdentifier: entry.bundleIdentifier, name: entry.name, icon: icon(for: entry.bundleIdentifier),
                               volume: entry.setting.volume, muted: entry.setting.muted, outputDeviceUID: entry.setting.outputDeviceUID)
        }
        viewModel.outputs = snapshot.outputs
        viewModel.systemOutput = audio.systemOutput()
        viewModel.captureStatus = engine.captureStatus
    }

    private var icons: [String: NSImage] = [:]
    private func icon(for bundleIdentifier: String) -> NSImage? {
        if let cached = icons[bundleIdentifier] { return cached }
        let path = runningApps.first { $0.bundleIdentifier == bundleIdentifier }?.bundlePath
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path
        guard let path else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[bundleIdentifier] = image
        return image
    }
}
