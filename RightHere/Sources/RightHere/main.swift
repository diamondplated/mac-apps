import AppKit
import FinderSync
import SwiftUI
import RightHereCore

if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    // Pure checks only: no extension state, no Finder, no preferences, nothing outside a temporary folder.
    let terminals = [Terminal(bundleIdentifier: "com.apple.Terminal", name: "Terminal")]
    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("righthere-selfcheck-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)) != nil else { exit(1) }
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let first = try? NewFile.create(in: sandbox, ext: "txt")
    let second = try? NewFile.create(in: sandbox, ext: "txt")
    var off = RightHereSettings(); off.showsNewFile = false; off.showsCopyPath = false
    let a = URL(fileURLWithPath: "/tmp/a/x"), b = URL(fileURLWithPath: "/tmp/b/y")
    let suite = "RightHereSelfCheck.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    guard first?.lastPathComponent == "untitled.txt", second?.lastPathComponent == "untitled 2.txt",
          MenuModel.entries(settings: RightHereSettings(), kind: .container) == [.newFile(extensions: ["txt", "md"]), .openTerminal, .copyPath],
          MenuModel.entries(settings: off, kind: .items) == [.openTerminal],
          MenuModel.entries(settings: RightHereSettings(), kind: .sidebar).isEmpty,
          Target.newFileFolder(selection: [a, b], targeted: URL(fileURLWithPath: "/tmp")) == URL(fileURLWithPath: "/tmp"),
          CopyPath.text(selection: [a, b], targeted: nil) == "/tmp/a/x\n/tmp/b/y",
          Terminal.resolve(saved: "com.example.gone", available: terminals) == (Terminal.fallbackIdentifier, true),
          (try? SettingsPatch(data: Data("{\"launchAtLogin\":true}".utf8), availableTerminals: terminals)) == nil,
          (try? SettingsPatch(data: Data("{\"launchAtLogin\":false,\"newFileExtensions\":[\"txt\"]}".utf8), availableTerminals: terminals)) != nil,
          (try? SettingsPatch(data: Data("{\"extensionEnabled\":true}".utf8), availableTerminals: terminals)) == nil,
          SettingsStore(defaults: defaults).settings == RightHereSettings()
    else { exit(1) }
    print("RightHere self-check passed (no extension, Finder or preference access).")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        window = NSWindow(contentRect: NSRect(origin: .zero, size: StatusView.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "RightHere"
        window.isReleasedWhenClosed = false
        window.center()
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Switching the extension on happens in System Settings; look again when the user comes back.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        window.contentView = NSHostingView(rootView: StatusView(isEnabled: FIFinderSyncController.isExtensionEnabled) {
            FIFinderSyncController.showExtensionManagementInterface()
        })
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit RightHere", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
