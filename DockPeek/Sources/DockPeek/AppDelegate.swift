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
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPreviewPanel()
        
        dockObserver.delegate = self
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
        
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let titleItem = NSMenuItem(title: "DockPeek \(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        statusMenu.addItem(titleItem)
        
        let isFullyAuthorized = (permissions.accessibilityStatus == .granted && permissions.screenCaptureStatus == .granted)
        let statusText = !preferences.previewsEnabled ? "Paused" : (isFullyAuthorized ? "● Ready & Active" : "⚠️ Permissions Required")
        let statusDescItem = NSMenuItem(title: "Status: \(statusText)", action: nil, keyEquivalent: "")
        statusDescItem.isEnabled = false
        statusMenu.addItem(statusDescItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let permHeader = NSMenuItem(title: "Permissions:", action: nil, keyEquivalent: "")
        permHeader.isEnabled = false
        statusMenu.addItem(permHeader)
        
        // Accessibility Permission
        let axStatusText = permissions.accessibilityStatus == .granted ? "✓ Granted" : "⚠️ Needs Permission (Click to open)"
        let axItem = NSMenuItem(
            title: "  Accessibility: \(axStatusText)",
            action: #selector(handleAccessibilityAction),
            keyEquivalent: ""
        )
        axItem.target = self
        statusMenu.addItem(axItem)
        
        // Screen Recording Permission
        let screenStatusText = permissions.screenCaptureStatus == .granted ? "✓ Granted" : "⚠️ Needs Permission (Click to open)"
        let screenItem = NSMenuItem(
            title: "  Screen Recording: \(screenStatusText)",
            action: #selector(handleScreenCaptureAction),
            keyEquivalent: ""
        )
        screenItem.target = self
        statusMenu.addItem(screenItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Restart (Crucial on macOS because Screen Recording permission requires process restart to take effect)
        let restartItem = NSMenuItem(title: "Restart DockPeek", action: #selector(restartApp), keyEquivalent: "r")
        restartItem.target = self
        statusMenu.addItem(restartItem)
        
        let managerItem = NSMenuItem(title: "Manage in Mac Tools…", action: #selector(openMacTools), keyEquivalent: "")
        managerItem.target = self
        statusMenu.addItem(managerItem)

        // Open System Settings
        let settingsItem = NSMenuItem(title: "Open Privacy & Security...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit DockPeek", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
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
        updateMenu()
    }

    @objc private func openMacTools() {
        let candidates = [URL(fileURLWithPath: "/Applications/Mac Tools.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Mac Tools.app")]
        if let manager = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: manager, configuration: .init())
        } else {
            let alert = NSAlert()
            alert.messageText = "Install Mac Tools to manage DockPeek"
            alert.informativeText = "Place Mac Tools in Applications, then open it to change DockPeek settings."
            alert.runModal()
        }
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
    
    @objc private func openSettings() {
        permissions.openAccessibilitySettings()
    }
    
    @objc private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
