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
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPreviewPanel()
        
        dockObserver.delegate = self
        dockObserver.start()
        
        // Initial permission check and prompt
        permissions.checkPermissions()
        if permissions.accessibilityStatus != .granted {
            permissions.requestAccessibility()
        }
        if permissions.screenCaptureStatus != .granted {
            permissions.requestScreenCapture()
        }
        
        // Poll permissions in background every 1.5s so that when the user grants access in
        // System Settings, DockPeek activates immediately without needing a manual refresh.
        permissionsPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let prevAx = self.permissions.accessibilityStatus
            let prevScreen = self.permissions.screenCaptureStatus
            self.permissions.checkPermissions()
            
            if prevAx != self.permissions.accessibilityStatus || prevScreen != self.permissions.screenCaptureStatus {
                self.updateMenu()
                if self.permissions.accessibilityStatus == .granted {
                    self.dockObserver.start()
                }
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
        
        let titleItem = NSMenuItem(title: "DockPeek v1.0", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        statusMenu.addItem(titleItem)
        
        let isFullyAuthorized = (permissions.accessibilityStatus == .granted && permissions.screenCaptureStatus == .granted)
        let statusText = isFullyAuthorized ? "● Ready & Active" : "⚠️ Permissions Required"
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
        previewPanel.onMouseEntered = { [weak self] in
            guard let self = self else { return }
            self.dockObserver.isMouseInsidePanel = true
            self.dockObserver.cancelDismissal()
        }
        previewPanel.onMouseMoved = { [weak self] in
            guard let self = self else { return }
            self.dockObserver.isMouseInsidePanel = true
            self.dockObserver.cancelDismissal()
        }
        previewPanel.onMouseExited = { [weak self] in
            guard let self = self else { return }
            self.dockObserver.isMouseInsidePanel = false
            let mousePt = NSEvent.mouseLocation
            if let dockFrame = self.dockObserver.currentDockItemFrame {
                let corridor = self.dockObserver.transitCorridor(between: dockFrame, and: self.previewPanel.frame)
                if corridor.contains(mousePt) {
                    return
                }
            }
            self.dockObserver.scheduleDismissal(delay: 0.6)
        }
    }
    
    // MARK: - DockObserverDelegate
    
    public func dockObserver(_ observer: DockObserver, didHoverItem item: HoveredDockItem) {
        windowService.fetchWindows(for: item.pid, appIcon: item.icon) { [weak self] windows in
            guard let self = self else { return }
            guard self.dockObserver.currentHoveredPID == item.pid else { return }
            
            guard !windows.isEmpty else {
                self.previewPanel.hide()
                return
            }
            
            self.previewPanel.show(
                dockItem: item,
                windows: windows,
                onSelect: { [weak self] selectedWin in
                    self?.windowService.raiseWindow(selectedWin)
                    self?.dockObserver.resetHoverState()
                },
                onClose: { [weak self] closedWin in
                    self?.windowService.closeWindow(closedWin)
                    // Refresh remaining windows after closing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self else { return }
                        self.windowService.fetchWindows(for: item.pid, appIcon: item.icon) { [weak self] remaining in
                            guard let self = self else { return }
                            guard self.dockObserver.currentHoveredPID == item.pid else { return }
                            if remaining.isEmpty {
                                self.previewPanel.hide()
                                self.dockObserver.resetHoverState()
                            } else {
                                self.previewPanel.show(
                                    dockItem: item,
                                    windows: remaining,
                                    onSelect: { [weak self] win in
                                        self?.windowService.raiseWindow(win)
                                        self?.dockObserver.resetHoverState()
                                    },
                                    onClose: { [weak self] win in
                                        self?.windowService.closeWindow(win)
                                    }
                                )
                            }
                        }
                    }
                }
            )
        }
    }
    
    public func dockObserverDidUnhover(_ observer: DockObserver) {
        previewPanel.hide()
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
