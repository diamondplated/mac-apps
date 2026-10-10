import AppKit
import SwiftUI
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

final class AppModel: ObservableObject {
    let preferences = Preferences()
    let engine = ScrollEngine()
    @Published var settings = ScrollSettings()
    @Published var active = false
    @Published var accessible = false
    @Published var monitoring = false
    @Published var error: String?
    @Published var launchAtLogin = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var statusObserver: NSObjectProtocol?
    init() {
        engine.didChange = { [weak self] active in self?.active = active }
        statusObserver = DistributedNotificationCenter.default().addObserver(forName: Preferences.statusRequest, object: Preferences.identifier, queue: .main) { [weak self] notification in
            guard let self, let token = notification.userInfo?["token"] as? String else { return }
            DistributedNotificationCenter.default().postNotificationName(Preferences.statusReply, object: token, userInfo: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "permissions": ["accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(), "eventTapActive": self.engine.active]
            ], deliverImmediately: true)
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: Preferences.changed, object: Preferences.identifier, queue: .main) { [weak self] _ in self?.reload() }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reload() }
    }
    func reload() {
        settings = preferences.settings
        accessible = AXIsProcessTrusted(); monitoring = CGPreflightListenEventAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine.configure(settings)
    }
    func set(_ key: String, _ value: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: value])
            try preferences.apply(SettingsPatch(data: data)); error = nil; reload()
        } catch { self.error = error.localizedDescription }
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

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 15) {
                Image(systemName: "computermouse.fill").font(.system(size: 32)).foregroundStyle(.teal).frame(width: 64, height: 64).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text("ScrollSplit").font(.largeTitle.bold())
                    Text("Your mouse. Your direction.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Circle().fill(model.active ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.active ? "Mouse scrolling is customized" : model.settings.enabled ? "Waiting for permission" : "Ready when you are").font(.headline)
                Spacer()
                Button(model.settings.enabled ? "Disable" : "Enable") {
                    if model.settings.enabled { model.set("enabled", false) } else { model.enableFromUserAction() }
                }.buttonStyle(.borderedProminent).tint(.teal)
            }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            Form {
                Section("Mouse wheel") {
                    Toggle("Reverse vertical scrolling", isOn: Binding(get: { model.settings.reverseVertical }, set: { model.set("reverseVertical", $0) }))
                    Toggle("Reverse horizontal scrolling", isOn: Binding(get: { model.settings.reverseHorizontal }, set: { model.set("reverseHorizontal", $0) }))
                    HStack {
                        Text("Scroll speed")
                        Slider(value: Binding(get: { model.settings.speedMultiplier }, set: { model.set("speedMultiplier", $0) }), in: 0.25...4, step: 0.25).accessibilityLabel("Mouse scroll speed")
                        Text(model.settings.speedMultiplier.formatted(.number.precision(.fractionLength(2))) + "×").monospacedDigit().frame(width: 52)
                    }
                }
                Section("Permissions") {
                    permission("Accessibility", granted: model.accessible, pane: "Privacy_Accessibility")
                    permission("Input Monitoring", granted: model.monitoring, pane: "Privacy_ListenEvent")
                }
                Section { Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.set("launchAtLogin", $0) })) }
            }.formStyle(.grouped)
            Text("Trackpad and other continuous scrolling stay unchanged. Some high-resolution mice also send continuous events and cannot be separated reliably; their scrolling stays unchanged too.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if model.settings.enabled && (!model.accessible || !model.monitoring) {
                Text("Grant ScrollSplit access in System Settings, then return here. If macOS requests a restart, quit and reopen ScrollSplit.").font(.callout).foregroundStyle(.secondary)
                Button("Request access again") { model.enableFromUserAction() }
            }
        }.padding(28).frame(width: 560, height: 640)
    }
    private func permission(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "lock.fill").foregroundStyle(granted ? Color.green : Color.secondary)
            Spacer()
            Button(granted ? "Open Settings" : "Review Access") { model.openPrivacy(pane) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var item: NSStatusItem!
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "ScrollSplit")
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "ScrollSplit Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit ScrollSplit", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        item.menu = menu
        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") { showSettings(); UserDefaults.standard.set(true, forKey: "hasOpenedSettings") }
    }
    @objc func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.title = "ScrollSplit"; created.styleMask = [.titled, .closable, .miniaturizable]; created.isReleasedWhenClosed = false; created.center()
            window = created
        }
        NSApplication.shared.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.engine.stop() }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
