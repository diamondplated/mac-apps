import AppKit
import CoreAudio
import Darwin
import SwiftUI
import MixBarCore
import MixBarDSP

if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    /// Records calls without touching Core Audio.
    final class RecordingAudio: AudioService {
        var created = 0, destroyed = 0
        var tapsAvailable: Bool { true }
        func createTap(_ spec: TapSpec, gain: Float) throws -> TapHandle { created += 1; return TapHandle(UInt64(created)) }
        func destroyTap(_ handle: TapHandle) { destroyed += 1 }
        func setGain(_ gain: Float, for handle: TapHandle) {}
        func health(of handle: TapHandle) -> TapHealth { TapHealth(framesRendered: 0, sawSignal: false) }
    }
    let now = Date()
    let helper = AudioProcess(objectID: 11, pid: 101, bundleIdentifier: "com.example.browser.helper", isRunningOutput: true)
    let main = AudioProcess(objectID: 10, pid: 100, bundleIdentifier: "com.example.browser", isRunningOutput: false)
    let groups = AppGrouping.group([main, helper], apps: [RunningApp(pid: 100, bundleIdentifier: "com.example.browser", name: "Browser")],
                                   excludingPID: 1, excludingBundleIdentifier: "com.andrew.mixbar")
    let snapshot = AudioSnapshot(groups: groups, outputs: [OutputDevice(uid: "speakers", name: "Speakers")], defaultOutputUID: "speakers")
    let audio = RecordingAudio()
    let engine = MixerEngine(service: audio)
    var half = AppVolume(bundleIdentifier: "com.example.browser", name: "Browser", volume: 0.5)
    engine.reconcile(snapshot, settings: { _ in half }, now: now)
    let tappedAtHalf = engine.live.count == 1 && audio.created == 1
    half.volume = 1
    engine.reconcile(snapshot, settings: { _ in half }, now: now)
    let removedAtNeutral = engine.live.isEmpty && audio.destroyed == 1

    // 200 percent of a full-scale signal stays inside full scale.
    var samples: [Float] = [1, -1, 1, -1]
    var output = [Float](repeating: 0, count: 4)
    let limited: Bool = samples.withUnsafeMutableBytes { input in
        output.withUnsafeMutableBytes { out in
            var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(input.count), mData: input.baseAddress))
            var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            guard let state = mb_render_state_create(48_000, 2) else { return false }
            defer { mb_render_state_destroy(state) }
            mb_render(state, &inputList, &outputList)
            return mb_saw_signal(state)
        }
    }
    guard groups.count == 1, groups[0].processObjectIDs == [10, 11], groups[0].isPlaying,
          tappedAtHalf, removedAtNeutral, limited, output.allSatisfy({ abs($0) <= 1 && abs($0) > 0.9 }),
          TapPlanner.spec(for: groups[0], setting: AppVolume(bundleIdentifier: "com.example.browser", name: "Browser"), outputs: snapshot.outputs, defaultOutputUID: "speakers") == nil,
          (try? SettingsPatch(data: Data("{\"audioCaptureStatus\":\"granted\"}".utf8))) == nil,
          (try? SettingsPatch(data: Data("{\"appVolumes\":[{\"bundleIdentifier\":\"a.b\",\"volume\":2.5,\"muted\":false}]}".utf8))) == nil,
          (try? SettingsPatch(data: Data("{\"remembersVolumes\":true,\"appVolumes\":[{\"bundleIdentifier\":\"com.apple.Music\",\"name\":\"x\",\"volume\":0.5,\"muted\":false,\"outputDeviceUID\":null}]}".utf8))) != nil
    else { exit(1) }
    _ = samples
    // Symbol lookups only: no tap, aggregate device, audio IO or permission prompt.
    let tapSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioHardwareCreateProcessTap") != nil
    print("Process taps: \(Preferences.audioControlAvailable && tapSymbol ? "available" : "unavailable (needs macOS 14.2)").")
    print("MixBar self-check passed (no process tap, aggregate device, audio IO, volume change or permission prompt).")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let managerIdentifier = "com.andrew.mactools"
    var mixer: MixerController!
    var item: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer = MixerController()
        mixer.viewModel.openSettings = { [weak self] in MainActor.assumeIsolated { self?.openSettings() } }
        mixer.viewModel.quit = { NSApplication.shared.terminate(nil) }
        mixer.viewModel.openPrivacySettings = { [weak self] in MainActor.assumeIsolated { self?.openPrivacySettings() } }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MixerView(model: mixer.viewModel))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "MixBar")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "MixBar"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        mixer.start()
        offerSetupOnFirstLaunch()
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = item.button else { return }
        mixer.mixerOpen = true
        mixer.updateViewModel()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { mixer.mixerOpen = false }

    /// Opens MixBar's page in Mac Tools. Older managers do not answer the page URL,
    /// so fall back to opening the manager, then to an install alert.
    func openSettings() {
        popover.performClose(nil)
        guard let page = URL(string: "mactools://app/mixBar") else { return }
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
        alert.informativeText = "Mac Tools holds MixBar's settings. Place it in Applications, then open it."
        alert.runModal()
    }

    /// Screen & System Audio Recording, where "System Audio Recording Only" apps are allowed.
    func openPrivacySettings() {
        popover.performClose(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    /// Opening the app again is the manager's Open button: show the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    private var needsAccess: Bool { mixer.engine.captureStatus == .denied && mixer.hasNonNeutralSettings }

    /// Once ever, so an update relaunch or a login launch never nags.
    private func offerSetupOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let offer = SetupOffer.shouldOffer(alreadyOffered: defaults.bool(forKey: "hasOfferedSetup"),
                                           launchedAsLoginItem: launchedAsLoginItem, needsAccess: needsAccess)
        defaults.set(true, forKey: "hasOfferedSetup")
        guard offer else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MixBar Needs Audio Access"
        alert.informativeText = "Allow MixBar under System Audio Recording so it can set each app's volume."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacySettings() }
    }

    private var launchedAsLoginItem: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) { mixer.stop() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
