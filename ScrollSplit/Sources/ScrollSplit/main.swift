import AppKit
import ApplicationServices
import ServiceManagement
import ScrollSplitCore

if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    var accumulator = WheelAccumulator()
    guard accumulator.scale(1, factor: 0.25) == 0,
          accumulator.scale(1, factor: 0.25) == 0,
          accumulator.scale(1, factor: 0.25) == 0,
          accumulator.scale(1, factor: 0.25) == 1,
          !WheelClassifier.shouldTransform(isContinuous: true, enabled: true, isOwnEvent: false) else { exit(1) }
    // A burst glides to exactly the notch total, and a reversal drops only what was owed.
    var glide = GlideAxis()
    var emitted: Int64 = 0
    glide.add(37, at: 0)
    emitted += glide.step(at: 0.05)
    glide.add(41, at: 0.05)
    for frame in 1...30 { emitted += glide.step(at: 0.05 + Double(frame) / 60) }
    var reversal = GlideAxis()
    var reversed: Int64 = reversal.step(at: 0)
    reversal.add(120, at: 0)
    reversed += reversal.step(at: 0.05)
    let dropped = reversal.add(-30, at: 0.05)
    for frame in 1...30 { reversed += reversal.step(at: 0.05 + Double(frame) / 60) }
    var router = SideButtonRouter()
    guard emitted == 78, glide.isIdle, reversed + dropped == 90, dropped > 0,
          !SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: .maskCommand),
          SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: false, isOwnEvent: false, flags: .maskShift),
          !SmoothScroll.shouldSmooth(enabled: true, smoothScrolling: true, isContinuous: true, isOwnEvent: false, flags: []),
          router.handle(isDown: true, button: 3, enabled: true, isOwnEvent: false) == .send(.back),
          router.handle(isDown: false, button: 3, enabled: true, isOwnEvent: false) == .swallow,
          router.handle(isDown: true, button: 2, enabled: true, isOwnEvent: false) == .pass,
          (try? SettingsPatch(data: Data("{\"mouseAccelerationAvailable\":true}".utf8))) == nil,
          (try? SettingsPatch(data: Data("{\"smoothScrolling\":true,\"sideButtonsNavigate\":false,\"mouseAccelerationOff\":true}".utf8))) != nil
    else { exit(1) }
    // Keyboard overrides: decisions only. No tap, hot key, key mapping, clipboard or audio device is touched.
    let safari = QuitTarget(pid: 42, bundleIdentifier: "com.apple.Safari")
    let finder = QuitTarget(pid: 1, bundleIdentifier: "com.apple.finder")
    func down(_ gate: inout HoldToQuitGate, _ target: QuitTarget, repeat isRepeat: Bool = false, at now: Double = 0) -> HoldToQuitGate.Action {
        gate.keyDown(keyCode: 12, flags: .maskCommand, isRepeat: isRepeat, enabled: true, now: now, frontmost: { target }, ownBundleIdentifier: nil, ownMenuOpen: false)
    }
    var hold = HoldToQuitGate()
    var early = HoldToQuitGate()
    var hyper = HyperKey()
    var ledger = KeyMappingLedger()
    let theirs = KeyMappingEntry(source: KeyMappingEntry.capsLock, destination: 0x7_0000_00E0)
    let added = ledger.adding(device: 7, current: [theirs]) ?? []
    let shortcut = "{\"keyCode\":9,\"carbonModifiers\":6144,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}"
    let shiftOnly = "{\"keyCode\":9,\"carbonModifiers\":512,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}"
    func patch(_ json: String, capsLock: Bool = true) -> SettingsPatch? { try? SettingsPatch(data: Data(json.utf8), capsLockRemapAvailable: capsLock) }
    guard down(&hold, safari) == .begin(safari), down(&hold, safari, repeat: true, at: 0.3) == .swallow,
          hold.tick(now: 0.5) == nil, hold.tick(now: 0.8) == safari, hold.keyUp(keyCode: 12) == .swallow,
          down(&early, safari) == .begin(safari), early.keyUp(keyCode: 12) == .cancel(passEvent: false), early.tick(now: 1) == nil,
          down(&early, finder) == .pass,
          hyper.key(keyCode: HyperKey.f18KeyCode, isDown: true, now: 0, tapIsEscape: true) == .swallow,
          hyper.key(keyCode: HyperKey.f18KeyCode, isDown: false, now: 0.1, tapIsEscape: true) == .sendEscape,
          hyper.key(keyCode: HyperKey.f18KeyCode, isDown: true, now: 1, tapIsEscape: true) == .swallow,
          hyper.key(keyCode: 4, isDown: true, now: 1.05, tapIsEscape: true) == .addHyper,
          hyper.key(keyCode: HyperKey.f18KeyCode, isDown: false, now: 1.1, tapIsEscape: true) == .swallow,
          hyper.key(keyCode: 4, isDown: true, now: 1.2, tapIsEscape: true) == .pass,
          added == [.capsLockToF18], ledger.removing(device: 7, current: added) == [theirs],
          {
              var cut = FinderCut()
              guard case .copy(let generation, let before) = cut.keyDown(keyCode: FinderCut.xKeyCode, flags: .maskCommand, isRepeat: false, enabled: true, isOwnEvent: false, frontmostBundleIdentifier: FinderCut.finderBundleIdentifier, changeCount: 1, focus: { .notText }) else { return false }
              cut.copyFinished(generation: generation, changeCountBefore: before, changeCountNow: 2)
              return cut.keyDown(keyCode: FinderCut.vKeyCode, flags: .maskCommand, isRepeat: false, enabled: true, isOwnEvent: false, frontmostBundleIdentifier: FinderCut.finderBundleIdentifier, changeCount: 2, focus: { .notText }) == .move
          }(),
          patch("{\"cutAndPasteFilesInFinder\":true}") != nil, patch("{\"cutAndPasteFilesInFinder\":1}") == nil,
          patch("{\"capsLockRemapAvailable\":true}") == nil,
          patch("{\"capsLockIsHyper\":true}", capsLock: false) == nil,
          patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":\(shiftOnly)}]}") == nil,
          patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"title\":\"\",\"shortcut\":\(shortcut)},{\"command\":\"toggleMicrophoneMute\",\"shortcut\":\(shortcut)}]}") == nil,
          patch("{\"holdToQuit\":true,\"capsLockIsHyper\":true,\"capsLockTapIsEscape\":true,\"shortcuts\":[{\"command\":\"pastePlainText\",\"title\":\"\",\"shortcut\":\(shortcut)}]}") != nil
    else { exit(1) }
    print("Pointer acceleration interface: \(PointerAcceleration.isAvailable ? "available" : "unavailable").")
    print("Caps Lock remap interface: \(CapsLockRemap.isAvailable ? "available" : "unavailable").")
    print("ScrollSplit self-check passed (no event tap, hot key, key mapping, clipboard, microphone or permission prompts).")
    exit(0)
}

@MainActor
final class AppModel {
    let preferences = Preferences()
    let engine = ScrollEngine()
    let keyboard = KeyboardEngine()
    let hotKeys = HotKeys()
    let microphone = Microphone()
    private var plainPaste = PlainPaste()
    private var pasteGeneration = 0
    private(set) var settings = ScrollSettings()
    private(set) var shortcuts: [ShortcutCommand: KeyShortcut] = [:]
    private(set) var accessible = false
    private(set) var monitoring = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    var didChange: (() -> Void)?

    var hasAccess: Bool { accessible && monitoring }
    var isActive: Bool { engine.active }

    init() {
        // A tap disabled by the system (for example after access is revoked) lands here:
        // refresh the access flags and restart the poll if access is now missing.
        engine.didChange = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessible = AXIsProcessTrusted(); self.monitoring = CGPreflightListenEventAccess()
                self.updatePoll()
                self.didChange?()
            }
        }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Preferences.statusRequest, object: Preferences.identifier, queue: .main) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                center.postNotificationName(Preferences.statusReply, object: token, userInfo: [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "permissions": ["accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(), "eventTapActive": self.engine.active]
                ], deliverImmediately: true)
            }
        })
        hotKeys.action = { [weak self] command in
            MainActor.assumeIsolated {
                switch command {
                case .pastePlainText: self?.pastePlainText()
                case .toggleMicrophoneMute: self?.microphone.toggle()
                }
            }
        }
        observers.append(center.addObserver(forName: Preferences.changed, object: Preferences.identifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        reload()
    }

    func reload() {
        settings = preferences.settings
        shortcuts = preferences.shortcuts.all
        accessible = AXIsProcessTrusted(); monitoring = CGPreflightListenEventAccess()
        engine.configure(settings)
        keyboard.configure(settings)
        // ScrollSplit's own switch is the master for the shortcuts too, and turning it off ends a mute.
        hotKeys.configure(settings.enabled ? shortcuts : [:])
        if !settings.enabled && microphone.isHoldingMute { microphone.unmute() }
        microphone.setListening(settings.enabled && shortcuts[.toggleMicrophoneMute] != nil)
        updatePoll()
        didChange?()
    }

    /// Access changes in System Settings post no notification, so poll only while
    /// the user wants ScrollSplit on and a permission is still missing.
    private func updatePoll() {
        let needsPoll = settings.enabled && !hasAccess
        if needsPoll, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        } else if !needsPoll, let timer {
            timer.invalidate(); self.timer = nil
        }
    }

    func set(_ key: String, _ value: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: value])
            try preferences.apply(SettingsPatch(data: data))
        } catch { NSLog("ScrollSplit could not save \(key): \(error.localizedDescription)") }
        reload()
    }

    func enableFromUserAction() {
        // Native requests are restricted to this explicit user action.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        set("enabled", true)
    }

    /// Puts only the clipboard's text on it, sends ⌘V to the frontmost app, and puts the
    /// original back shortly after unless something else wrote to the clipboard meanwhile.
    /// The clipboard is read only here, at the moment the shortcut is pressed.
    private func pastePlainText() {
        guard AXIsProcessTrusted(), let target = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let pasteboard = SystemPasteboard(.general)
        guard plainPaste.press(pasteboard) else { return }
        postKeyPress(9, character: "v", flags: .maskCommand, to: target)
        pasteGeneration += 1
        let generation = pasteGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.pasteGeneration else { return }
                self.plainPaste.restore(pasteboard)
            }
        }
    }

    /// The microphone is muted and ScrollSplit has a say in it.
    var microphoneMuted: Bool {
        // Judged by the device actually in use: a headset that cannot be muted reads live.
        (microphone.isHoldingMute || (settings.enabled && shortcuts[.toggleMicrophoneMute] != nil)) && microphone.isMuted
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let managerIdentifier = "com.andrew.mactools"
    var model: AppModel!
    var item: NSStatusItem!
    private var alertShowing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "ScrollSplit")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu(menu)
        model.didChange = { [weak self] in self?.updateIcon() }
        model.microphone.didChange = { [weak self] in MainActor.assumeIsolated { self?.updateIcon() } }
        updateIcon()
        offerSetupOnFirstLaunch()
    }

    private var isWorking: Bool { model.settings.enabled && model.hasAccess && model.isActive }

    private var statusTitle: String {
        if !model.settings.enabled { return "Off" }
        return isWorking ? "On" : "Needs Access"
    }

    private var shownMuted: Bool?

    /// A crossed-out microphone while muted, so the state is always visible.
    private func updateIcon() {
        let muted = model.microphoneMuted
        if shownMuted != muted {
            shownMuted = muted
            item.button?.image = NSImage(systemSymbolName: muted ? "mic.slash" : "computermouse",
                                         accessibilityDescription: muted ? "ScrollSplit, Microphone Muted" : "ScrollSplit")
        }
        item.button?.appearsDisabled = !isWorking && !muted
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.keyboard.ownMenuOpen = true
        model.reload()
        rebuildMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) { model.keyboard.ownMenuOpen = false }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.microphoneMuted {
            let muted = NSMenuItem(title: "Microphone Muted", action: nil, keyEquivalent: "")
            muted.isEnabled = false
            menu.addItem(muted)
            add("Unmute Microphone", #selector(unmuteMicrophone), to: menu)
            menu.addItem(.separator())
        }
        let status = NSMenuItem(title: "ScrollSplit Is \(statusTitle)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add(model.settings.enabled ? "Turn Off" : "Turn On", #selector(toggle), to: menu)
        if !model.accessible { add("Grant Accessibility…", #selector(grantAccessibility), to: menu) }
        if !model.monitoring { add("Grant Input Monitoring…", #selector(grantInputMonitoring), to: menu) }
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("Quit ScrollSplit", #selector(quitApp), key: "q", to: menu)
    }

    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
    }

    @objc private func toggle() {
        if model.settings.enabled { model.set("enabled", false) } else { model.enableFromUserAction() }
    }

    @objc private func unmuteMicrophone() {
        if model.microphone.isMuted { model.microphone.toggle() } else { model.microphone.unmute() }
    }

    @objc private func grantAccessibility() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        model.openPrivacy("Privacy_Accessibility")
    }

    @objc private func grantInputMonitoring() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        model.openPrivacy("Privacy_ListenEvent")
    }

    /// Opens ScrollSplit's page in Mac Tools. Older managers do not answer the
    /// page URL, so fall back to opening the manager, then to an install alert.
    @objc func openSettings() {
        guard let page = URL(string: "mactools://app/scrollSplit") else { return }
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
        alert.informativeText = "Mac Tools holds ScrollSplit's settings. Place it in Applications, then open it."
        alert.runModal()
    }

    /// Opening the app again is the manager's Open button: offer to turn
    /// scrolling on when it is not working, and do nothing when it is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reload()
        offerSetup()
        return false
    }

    /// The one setup alert, shared by reopen and the first launch.
    private func offerSetup() {
        guard !alertShowing, !isWorking else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let needsAccess = model.settings.enabled
        let alert = NSAlert()
        alert.messageText = needsAccess ? "ScrollSplit Needs Access" : "ScrollSplit Is Off"
        alert.informativeText = needsAccess ? "Allow Accessibility and Input Monitoring to customize mouse scrolling." : "Turn it on to customize mouse scrolling."
        alert.addButton(withTitle: needsAccess ? "Grant Access" : "Turn On")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { model.enableFromUserAction() }
    }

    /// Once ever, so an update relaunch or a deliberately-off app never nags.
    private func offerSetupOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let offer = SetupOffer.shouldOffer(alreadyOffered: defaults.bool(forKey: "hasOfferedSetup"),
                                           launchedAsLoginItem: launchedAsLoginItem, isWorking: isWorking)
        defaults.set(true, forKey: "hasOfferedSetup")
        if offer { offerSetup() }
    }

    private var launchedAsLoginItem: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Every override ends with ScrollSplit: taps, the Caps Lock mapping, hot keys and any mute.
    func applicationWillTerminate(_ notification: Notification) {
        model.engine.stop()
        model.keyboard.stop()
        model.hotKeys.unregisterAll()
        model.microphone.unmute()
    }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
