import Cocoa
import SwiftUI
import ApplicationServices

public class AppDelegate: NSObject, NSApplicationDelegate, DockObserverDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let dockObserver = DockObserver()
    private let previewPanel = PreviewPanel()
    private let windowService = WindowService.shared
    private let permissions = PermissionsManager.shared
    private var permissionsPollTimer: Timer?
    private var previewRequestID = UUID()
    private let preferences = ToolPreferences.shared
    private let switcher = SwitcherController()
    private let dockClicks = DockClickController()
    private let layouts = LayoutController()
    private var layoutResult: (text: String, date: Date)?
    private var statusAnswerer: NSObjectProtocol?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPreviewPanel()
        layouts.onResult = { [weak self] text in self?.layoutResult = (text, Date()) }
        
        dockObserver.delegate = self
        statusAnswerer = RunningAppPermissions.startAnswering()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(settingsDidChange),
            name: ToolPreferences.changedNotification, object: ToolPreferences.bundleIdentifier
        )
        
        // Initial permission check and prompt
        permissions.checkPermissions()
        if permissions.accessibilityStatus != .granted {
            permissions.requestAccessibility()
        }
        if permissions.screenCaptureStatus != .granted {
            permissions.requestScreenCapture()
        }
        
        applyPreferences()

        // Poll permissions in background every 1.5s so that when the user grants access in
        // System Settings, DockPeek activates immediately without needing a manual refresh.
        permissionsPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let prevAx = self.permissions.accessibilityStatus
            let prevScreen = self.permissions.screenCaptureStatus
            self.permissions.checkPermissions()
            
            if prevAx != self.permissions.accessibilityStatus || prevScreen != self.permissions.screenCaptureStatus {
                self.applyPreferences()
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "DockPeek")
        }
        
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateMenu()
    }
    
    // MARK: - NSMenuDelegate
    
    public func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }
    
    private func updateMenu() {
        permissions.checkPermissions()
        statusMenu.removeAllItems()

        let axGranted = permissions.accessibilityStatus == .granted
        let screenGranted = permissions.screenCaptureStatus == .granted
        let statusText = !preferences.previewsEnabled ? "Previews Paused" : (axGranted && screenGranted ? "Previews On" : "Needs Permission")
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusMenu.addItem(statusItem)

        if !axGranted || !screenGranted {
            statusMenu.addItem(.separator())
            if !axGranted { addItem("Grant Accessibility…", #selector(handleAccessibilityAction)) }
            if !screenGranted { addItem("Grant Screen Recording…", #selector(handleScreenCaptureAction)) }
        }

        statusMenu.addItem(.separator())
        if let result = layoutResult, Date().timeIntervalSince(result.date) < 120 {
            let line = NSMenuItem(title: result.text, action: nil, keyEquivalent: "")
            line.isEnabled = false
            statusMenu.addItem(line)
        }
        addItem("Save Window Layout", #selector(saveLayout))
        addItem("Restore Window Layout", #selector(restoreLayout))
        // Holding Option swaps in the item that clears everything remembered.
        let forget = statusMenu.addItem(withTitle: "Forget Saved Layouts", action: #selector(forgetLayouts), keyEquivalent: "")
        forget.target = self
        forget.isAlternate = true
        forget.keyEquivalentModifierMask = .option
        statusMenu.addItem(.separator())
        addItem("Settings…", #selector(openSettings), key: ",")
        statusMenu.addItem(.separator())
        addItem("Quit DockPeek", #selector(quitApp), key: "q")
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "") {
        let item = statusMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    private func setupPreviewPanel() {
        dockObserver.previewPanel = previewPanel
        let recheckPointer: () -> Void = { [weak self] in
            self?.dockObserver.recheckPointerPosition()
        }
        previewPanel.onMouseEntered = recheckPointer
        previewPanel.onMouseMoved = recheckPointer
        previewPanel.onMouseExited = recheckPointer
    }
    
    // MARK: - DockObserverDelegate
    
    public func dockObserver(_ observer: DockObserver, didHoverItem item: HoveredDockItem) {
        refreshPreview(for: item)
    }

    private func refreshPreview(for item: HoveredDockItem) {
        guard preferences.previewsEnabled else { return }
        let requestID = UUID()
        previewRequestID = requestID
        windowService.fetchWindows(for: item.pid, appIcon: item.icon, showsTabs: preferences.showsTabs) { [weak self] windows in
            guard let self = self,
                  self.preferences.previewsEnabled,
                  self.previewRequestID == requestID,
                  self.dockObserver.currentHoveredPID == item.pid else { return }
            guard !windows.isEmpty else {
                self.previewPanel.hide()
                return
            }
            self.previewPanel.show(
                dockItem: item,
                windows: windows,
                onSelect: { [weak self] window in
                    self?.windowService.raiseWindow(window)
                    self?.dockObserver.resetHoverState()
                },
                onClose: { [weak self] window in
                    self?.windowService.closeWindow(window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self,
                              self.previewRequestID == requestID,
                              self.dockObserver.currentHoveredPID == item.pid else { return }
                        self.refreshPreview(for: item)
                    }
                },
                onSelectTab: { [weak self] tab, window in
                    guard let self = self else { return false }
                    if self.windowService.selectTab(tab, in: window) {
                        self.dockObserver.resetHoverState()
                        return true
                    }
                    // A tab may have closed since this preview was fetched.
                    self.refreshPreview(for: item)
                    return false
                }
            )
        }
    }

    public func dockObserverDidUnhover(_ observer: DockObserver) {
        previewRequestID = UUID()
        previewPanel.hide()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyPreferences() }
    }

    private func applyPreferences() {
        preferences.synchronize()
        previewRequestID = UUID()
        previewPanel.hide()
        dockObserver.dismissalDelay = preferences.dismissalDelay
        permissions.checkPermissions()
        if preferences.previewsEnabled,
           permissions.accessibilityStatus == .granted,
           permissions.screenCaptureStatus == .granted {
            dockObserver.start()
        } else {
            dockObserver.stop()
        }
        // Each tap exists only while its feature is on and Accessibility allows it.
        let axGranted = permissions.accessibilityStatus == .granted
        switcher.apply(
            enabled: preferences.switcherEnabled,
            accessibilityGranted: axGranted,
            screenRecordingGranted: permissions.screenCaptureStatus == .granted
        )
        dockClicks.apply(preferences.dockClickSettings, accessibilityGranted: axGranted)
        layouts.apply(automatic: preferences.restoresWindowLayouts, accessibilityGranted: axGranted)
        updateMenu()
    }

    /// Opens DockPeek's page in Mac Tools. Older managers do not answer the page
    /// URL, so fall back to opening the manager, then to an install alert.
    @objc private func openSettings() {
        guard let page = URL(string: "mactools://app/dockPeek") else { return }
        NSWorkspace.shared.open(page, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.openManager() }
        }
    }

    private func openManager() {
        guard let manager = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.andrew.mactools") else { return showInstallAlert() }
        NSWorkspace.shared.openApplication(at: manager, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.showInstallAlert() } }
        }
    }

    private func showInstallAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Mac Tools"
        alert.informativeText = "Mac Tools holds DockPeek's settings. Place it in Applications, then open it."
        alert.runModal()
    }

    // MARK: - Actions
    
    @objc private func handleAccessibilityAction() {
        permissions.requestAccessibility()
        permissions.openAccessibilitySettings()
        updateMenu()
    }
    
    @objc private func handleScreenCaptureAction() {
        permissions.requestScreenCapture()
        permissions.openScreenCaptureSettings()
        updateMenu()
    }
    
    @objc private func saveLayout() { layouts.saveNow() }
    @objc private func restoreLayout() { layouts.restoreNow() }
    @objc private func forgetLayouts() { layouts.forgetAll() }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
