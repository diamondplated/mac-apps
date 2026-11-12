import AppKit
import ApplicationServices
import ServiceManagement
import StayLitCore

if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    /// Counts takes and releases without touching IOKit.
    final class CountingPower: PowerService {
        var held = 0
        func takeAssertion(_ kind: AssertionKind, reason: String) -> UInt32? { held += 1; return UInt32(held) }
        func releaseAssertion(_ id: UInt32) { held -= 1 }
    }
    let now = Date()
    var state = KeepAwakeState()
    state.apps = ["com.example.app"]
    state.running.launched(pid: 1, bundleIdentifier: "com.example.app", name: "Example")
    let power = CountingPower()
    let keeper = AssertionKeeper(service: power)
    keeper.update(state.shouldBeAwake(at: now) ? .system : nil)
    let heldWhileRunning = power.held
    state.running.terminated(pid: 1)
    keeper.update(state.shouldBeAwake(at: now) ? .system : nil)
    var timed = KeepAwakeState()
    timed.keepAwake(for: 42 * 60, from: now)
    let cut = timed.settle(at: now, power: PowerSource(onBattery: true, percent: 19))
    let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
    let dell = DisplayInfo(id: 3, name: "External", isBuiltin: false, vendor: 0x10AC, brightness: DDC.Value(current: 50, maximum: 100))
    let builtIn = DisplayInfo(id: 1, name: "Built-in", isBuiltin: true, vendor: DisplayInfo.appleVendor)
    var limiter = WriteLimiter(interval: 0.06)
    guard heldWhileRunning == 1, power.held == 0, cut, !timed.shouldBeAwake(at: now),
          AwakeSentence.sentence(for: .timed(until: now.addingTimeInterval(42 * 60)), now: now) == "Awake for 42 more minutes",
          AwakeSentence.sentence(for: .apps(["Xcode"]), now: now) == "Awake while Xcode is running",
          DDC.readRequest(0x10) == [0x82, 0x01, 0x10, 0xAC],
          DDC.writeRequest(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A],
          DDC.parseReply(reply, expecting: 0x10) == DDC.Value(current: 50, maximum: 100),
          limiter.request(1, at: 0) == .write(1), limiter.request(2, at: 0.01) == .schedule(at: 0.06),
          KeyRouter.decide(.brightnessUp, pointerDisplay: dell, volumeDisplay: nil, displays: [dell], brightnessOn: true, volumeOn: false) == .brightness(display: 3, up: true),
          KeyRouter.decide(.brightnessUp, pointerDisplay: builtIn, volumeDisplay: nil, displays: [builtIn], brightnessOn: true, volumeOn: true) == .pass,
          KeyRouter.decide(.brightnessUp, pointerDisplay: dell, volumeDisplay: nil, displays: [dell], brightnessOn: false, volumeOn: true) == .pass,
          MediaKeyEvent(subtype: 8, data1: 2 << 16 | 0x0A << 8)?.key == .brightnessUp,
          (try? SettingsPatch(data: Data("{\"awakeReason\":\"x\"}".utf8))) == nil,
          (try? SettingsPatch(data: Data("{\"keepAwake\":1}".utf8))) == nil,
          (try? SettingsPatch(data: Data("{\"keepAwake\":true,\"keepAwakeApps\":[\"com.apple.dt.Xcode\"],\"keepsDisplayAwake\":false,\"brightnessKeysControlDisplays\":false,\"volumeKeysControlDisplays\":false}".utf8))) != nil
    else { exit(1) }
    print("Display control interface: \(DDCChannel.isAvailable ? "available" : "unavailable").")
    print("StayLit self-check passed (no power assertion, event tap, display access or permission prompts).")
    exit(0)
}

@MainActor
final class AppModel {
    let preferences = Preferences()
    let displays = DisplayController()
    let audio = AudioOutputMonitor()
    let tap = MediaKeyTap()
    let indicator = IndicatorPanel()
    private let keeper = AssertionKeeper(service: IOKitPowerService())
    private let powerMonitor = PowerSourceMonitor()
    private(set) var settings = StayLitSettings()
    private(set) var state = KeepAwakeState()
    private(set) var chosenDuration: TimeInterval?
    private(set) var accessible = false
    private var observers: [NSObjectProtocol] = []
    private var deadline: Timer?
    private var accessPoll: Timer?
    private var runningObservation: NSKeyValueObservation?
    private var screenChange: DispatchWorkItem?
    var didChange: (() -> Void)?

    var needsAccess: Bool { settings.wantsKeyTap && !accessible }

    init() {
        syncRunningApps()
        // runningApplications is key-value observable for every app, including menu bar
        // and background apps that post no launch or quit notification.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncRunningApps(); self?.evaluate() } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Preferences.statusRequest, object: Preferences.identifier, queue: .main) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                var info: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                           "permissions": ["accessibility": AXIsProcessTrusted()],
                                           "externalDisplays": self.displays.externalDisplays]
                if let sentence = self.sentence { info["awakeReason"] = sentence }
                center.postNotificationName(Preferences.statusReply, object: token, userInfo: info, deliverImmediately: true)
            }
        })
        observers.append(center.addObserver(forName: Preferences.changed, object: Preferences.identifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        powerMonitor.onChange = { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        powerMonitor.start()
        displays.didChange = { [weak self] in MainActor.assumeIsolated { self?.didChange?() } }
        audio.onChange = { [weak self] in MainActor.assumeIsolated { self?.didChange?() } }
        tap.decide = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return .pass }
                let volumeDisplay = VolumeTarget.resolve(output: self.audio.output, displays: self.displays.displays)
                return KeyRouter.decide(key, pointerDisplay: self.displays.pointerDisplay(), volumeDisplay: volumeDisplay, displays: self.displays.displays,
                                        brightnessOn: self.settings.brightnessKeysControlDisplays, volumeOn: self.settings.volumeKeysControlDisplays)
            }
        }
        tap.perform = { [weak self] claim in MainActor.assumeIsolated { self?.perform(claim) } }
        tap.didChange = { [weak self] in MainActor.assumeIsolated { self?.didChange?() } }
        reload()
        refreshDisplays()
    }

    /// The sentence the menu's first line and the bridge's `awakeReason` share.
    var sentence: String? { AwakeSentence.sentence(for: state.reason(at: Date()), now: Date()) }
    var isAwake: Bool { state.shouldBeAwake(at: Date()) }
    var userKeepAwakeIsOn: Bool { state.userKeepAwakeIsOn(at: Date()) }

    func reload() {
        settings = preferences.settings
        syncRunningApps()
        if settings.keepAwake && !state.manual { state.turnOnManually(); chosenDuration = nil }
        if !settings.keepAwake && state.manual { state.manual = false }
        state.apps = settings.keepAwakeApps
        accessible = AXIsProcessTrusted()
        tap.setWanted(settings.wantsKeyTap)
        if settings.volumeKeysControlDisplays { audio.start() } else { audio.stop() }
        if settings.wantsKeyTap && displays.needsProbe { displays.refresh(probe: true) }
        updateAccessPoll()
        evaluate()
    }

    private func refreshDisplays() { displays.refresh(probe: settings.wantsKeyTap) }

    /// Displays arrive in bursts when one connects; list them once the burst settles.
    private func screensChanged() {
        screenChange?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshDisplays() } }
        screenChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func syncRunningApps() {
        var running = RunningApps()
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            running.launched(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
        }
        state.running = running
    }

    /// Combines every reason into one answer and holds or releases the assertion to match.
    func evaluate() {
        let now = Date()
        if state.settle(at: now, power: PowerSourceMonitor.current), settings.keepAwake {
            write("keepAwake", false)
            settings.keepAwake = false
        }
        if !state.userKeepAwakeIsOn(at: now) { chosenDuration = nil }
        keeper.update(state.shouldBeAwake(at: now) ? (settings.keepsDisplayAwake ? .display : .system) : nil)
        deadline?.invalidate(); deadline = nil
        if let next = state.nextDeadline(after: now) {
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            RunLoop.main.add(timer, forMode: .common)
            deadline = timer
        }
        didChange?()
    }

    /// Accessibility changes post no notification, so poll while a display-key switch is on:
    /// to install the tap once access is granted, and to remove it if access is revoked.
    private func updateAccessPoll() {
        if settings.wantsKeyTap, accessPoll == nil {
            accessPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() != self.accessible else { return }
                    self.reload()
                }
            }
        } else if !settings.wantsKeyTap, let accessPoll {
            accessPoll.invalidate(); self.accessPoll = nil
        }
    }

    private func perform(_ claim: KeyClaim) {
        let model: IndicatorModel?
        let target: UInt32
        switch claim {
        case .pass: return
        case .brightness(let display, let up): model = displays.adjustBrightness(display, up: up); target = display
        case .volume(let display, let up): model = displays.adjustVolume(display, up: up); target = display
        case .mute(let display): model = displays.adjustVolume(display, up: nil); target = display
        }
        // Brightness shows on the display that changed; volume on the display under the pointer.
        let shownOn: UInt32
        if case .brightness = claim { shownOn = target } else { shownOn = displays.pointerDisplay()?.id ?? target }
        if let model { indicator.show(model, on: shownOn) }
    }

    // MARK: Menu actions

    func keepAwakeUntilTurnedOff() {
        state.turnOnManually()
        chosenDuration = nil
        write("keepAwake", true)
        reload()
    }

    func keepAwake(for duration: TimeInterval) {
        state.keepAwake(for: duration, from: Date())
        chosenDuration = duration
        settings.keepAwake = false
        write("keepAwake", false)
        reload()
    }

    func turnOff() {
        state.turnOffUserKeepAwake()
        chosenDuration = nil
        write("keepAwake", false)
        reload()
    }

    func toggleApp(_ identifier: String) {
        var list = settings.keepAwakeApps
        if let index = list.firstIndex(of: identifier) { list.remove(at: index) } else { list.append(identifier) }
        write("keepAwakeApps", list)
        reload()
    }

    private func write(_ key: String, _ value: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: value])
            try preferences.apply(SettingsPatch(data: data))
        } catch { NSLog("StayLit could not save \(key): \(error.localizedDescription)") }
    }

    func requestAccess() {
        // Native requests are restricted to this explicit user action.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    /// Quitting releases everything.
    func stop() {
        deadline?.invalidate()
        accessPoll?.invalidate()
        runningObservation = nil
        keeper.releaseAll()
        tap.remove()
        audio.stop()
        powerMonitor.stop()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let managerIdentifier = "com.andrew.mactools"
    var model: AppModel!
    var item: NSStatusItem!
    private var alertShowing = false
    private var frontmost: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu(menu)
        model.didChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        offerSetupOnFirstLaunch()
    }

    private func updateIcon() {
        let awake = model.isAwake
        let image = NSImage(systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
                            accessibilityDescription: awake ? "StayLit, keeping this Mac awake" : "StayLit")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = model.sentence
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A menu bar app's menu opens without activating it, so this is the app the user was in.
        frontmost = NSWorkspace.shared.frontmostApplication
        model.reload()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.sentence ?? AwakeSentence.idleTitle(endedForLowBattery: model.state.endedForLowBattery), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Keep Awake", #selector(toggleKeepAwake), to: menu).state = model.userKeepAwakeIsOn ? .on : .off

        let durations = NSMenu()
        for (title, seconds) in [("30 Minutes", 1800.0), ("1 Hour", 3600.0), ("2 Hours", 7200.0)] {
            let entry = add(title, #selector(keepAwakeFor(_:)), to: durations)
            entry.tag = Int(seconds)
            entry.state = model.chosenDuration == seconds && model.userKeepAwakeIsOn ? .on : .off
        }
        durations.addItem(.separator())
        add("Until I Turn It Off", #selector(keepAwakeUntilTurnedOff), to: durations).state = model.state.manual ? .on : .off
        let durationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(durationItem)

        if let app = frontmost, let identifier = app.bundleIdentifier, identifier != Bundle.main.bundleIdentifier,
           BundleIdentifier.isValid(identifier) {
            let listed = model.settings.keepAwakeApps.contains(identifier)
            let entry = add("Keep Awake While \(app.localizedName ?? identifier) Is Running", #selector(toggleFrontmostApp), to: menu)
            entry.state = listed ? .on : .off
            entry.representedObject = identifier
            if !listed && model.settings.keepAwakeApps.count >= BundleIdentifier.maximumApps { entry.isEnabled = false; entry.action = nil }
        }
        menu.addItem(.separator())
        if model.needsAccess { add("Grant Accessibility…", #selector(grantAccessibility), to: menu) }
        add("Settings…", #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("Quit StayLit", #selector(quitApp), key: "q", to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func toggleKeepAwake() {
        if model.userKeepAwakeIsOn { model.turnOff() } else { model.keepAwakeUntilTurnedOff() }
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) { model.keepAwake(for: TimeInterval(sender.tag)) }
    @objc private func keepAwakeUntilTurnedOff() { model.keepAwakeUntilTurnedOff() }

    @objc private func toggleFrontmostApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        model.toggleApp(identifier)
    }

    @objc private func grantAccessibility() { model.requestAccess() }

    /// Opens StayLit's page in Mac Tools. Older managers do not answer the
    /// page URL, so fall back to opening the manager, then to an install alert.
    @objc func openSettings() {
        guard let page = URL(string: "mactools://app/stayLit") else { return }
        NSWorkspace.shared.open(page, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.openManager() }
        }
    }

    private func openManager() {
        guard let manager = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.managerIdentifier) else { return showInstallAlert() }
        NSWorkspace.shared.openApplication(at: manager, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.showInstallAlert() } }
        }
    }

    private func showInstallAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Mac Tools"
        alert.informativeText = "Mac Tools holds StayLit's settings. Place it in Applications, then open it."
        alert.runModal()
    }

    /// Opening the app again is the manager's Open button: offer access when a
    /// display-key switch is waiting for it, and do nothing otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reload()
        offerSetup()
        return false
    }

    /// The one setup alert, shared by reopen and the first launch.
    private func offerSetup() {
        guard !alertShowing, model.needsAccess else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "StayLit Needs Access"
        alert.informativeText = "Allow Accessibility so the brightness and volume keys can control external displays."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { model.requestAccess() }
    }

    /// Once ever, so an update relaunch or a login launch never nags.
    private func offerSetupOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let offer = SetupOffer.shouldOffer(alreadyOffered: defaults.bool(forKey: "hasOfferedSetup"),
                                           launchedAsLoginItem: launchedAsLoginItem, needsAccess: model.needsAccess)
        defaults.set(true, forKey: "hasOfferedSetup")
        if offer { offerSetup() }
    }

    private var launchedAsLoginItem: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
