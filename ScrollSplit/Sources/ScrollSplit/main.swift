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
    print("ScrollSplit self-check passed (no event tap or permission prompts).")
    exit(0)
}

@MainActor
final class AppModel {
    let preferences = Preferences()
    let engine = ScrollEngine()
    private(set) var settings = ScrollSettings()
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
        observers.append(center.addObserver(forName: Preferences.changed, object: Preferences.identifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        reload()
    }

    func reload() {
        settings = preferences.settings
        accessible = AXIsProcessTrusted(); monitoring = CGPreflightListenEventAccess()
        engine.configure(settings)
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
        updateIcon()
    }

    private var isWorking: Bool { model.settings.enabled && model.hasAccess && model.isActive }

    private var statusTitle: String {
        if !model.settings.enabled { return "Off" }
        return isWorking ? "On" : "Needs Access"
    }

    private func updateIcon() {
        item.button?.appearsDisabled = !isWorking
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.reload()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
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
        guard !alertShowing, !isWorking else { return false }
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
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model.engine.stop() }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
