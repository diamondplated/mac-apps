import Foundation
import Cocoa
import ApplicationServices

public enum DockOrientation {
    case bottom
    case left
    case right
}

public struct HoveredDockItem {
    public let pid: pid_t
    public let title: String
    public let icon: NSImage?
    public let frame: CGRect
    public let orientation: DockOrientation
}

public protocol DockObserverDelegate: AnyObject {
    func dockObserver(_ observer: DockObserver, didHoverItem item: HoveredDockItem)
    func dockObserverDidUnhover(_ observer: DockObserver)
}

public class DockObserver {
    public weak var delegate: DockObserverDelegate?
    public weak var previewPanel: NSPanel?
    
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dismissTimer: Timer?
    public private(set) var currentHoveredPID: pid_t?
    public private(set) var currentDockItemFrame: CGRect?
    public var isMouseInsidePanel: Bool = false
    
    private let systemWideElement = AXUIElementCreateSystemWide()
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public func start() {
        stop()
        
        // Listen to global mouse movement across the desktop and dock
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
        }
        
        // Listen to local mouse movement in our own process windows
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
            return event
        }
    }
    
    public func stop() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentHoveredPID = nil
        currentDockItemFrame = nil
        isMouseInsidePanel = false
    }
    
    /// Determines screen containing given point, falling back to primary screen
    public static func screen(for point: CGPoint) -> NSScreen {
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen()
    }
    
    /// Determines Dock orientation based on the screen's visibleFrame vs full frame
    public func dockOrientation(for screen: NSScreen) -> DockOrientation {
        let visibleFrame = screen.visibleFrame
        let fullFrame = screen.frame
        
        if visibleFrame.origin.x > fullFrame.origin.x {
            return .left
        } else if visibleFrame.maxX < fullFrame.maxX {
            return .right
        } else {
            return .bottom
        }
    }
    
    public var dockOrientation: DockOrientation {
        if let dockFrame = currentDockItemFrame {
            return dockOrientation(for: Self.screen(for: dockFrame.origin))
        }
        return dockOrientation(for: Self.screen(for: NSEvent.mouseLocation))
    }
    
    /// Converts Cocoa mouse location (bottom-left origin) to Carbon/AX display coordinates (top-left origin)
    private func carbonCoordinates(from cocoaPoint: NSPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return CGPoint(x: cocoaPoint.x, y: cocoaPoint.y)
        }
        let primaryHeight = primaryScreen.frame.height
        return CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
    }
    
    /// Converts AX display coordinates (top-left origin) to Cocoa screen coordinates (bottom-left origin)
    public static func cocoaRect(fromCarbonRect carbonRect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return carbonRect }
        let primaryHeight = primaryScreen.frame.height
        let y = primaryHeight - carbonRect.origin.y - carbonRect.height
        return CGRect(x: carbonRect.origin.x, y: y, width: carbonRect.width, height: carbonRect.height)
    }
    
    /// Calculates the full transit corridor between the dock item and the preview panel,
    /// expanded generously to permit natural diagonal cursor movement without accidental dismissal.
    public func transitCorridor(between dockRect: CGRect, and panelRect: CGRect) -> CGRect {
        return dockRect.union(panelRect).insetBy(dx: -25, dy: -20)
    }
    
    private struct DockItemInfo {
        let title: String
        let rect: CGRect
        let element: AXUIElement
    }
    
    /// Queries Accessibility to see if a Dock application icon is under the given Carbon coordinate
    private func findDockItem(at carbonPoint: CGPoint) -> DockItemInfo? {
        var elementUnderMouse: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(carbonPoint.x), Float(carbonPoint.y), &elementUnderMouse)
        guard result == .success, let element = elementUnderMouse else { return nil }
        
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dockApp.processIdentifier == pid else { return nil }
        
        // Climb element hierarchy up to 3 levels to locate AXApplicationDockItem or AXDockItem
        var currentElement = element
        var dockItemElement: AXUIElement?
        for _ in 0..<3 {
            var roleValue: AnyObject?
            if AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               role == "AXApplicationDockItem" || role == "AXDockItem" {
                dockItemElement = currentElement
                break
            }
            var parentValue: AnyObject?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue) == .success,
               let parent = parentValue {
                currentElement = (parent as! AXUIElement)
            } else {
                break
            }
        }
        
        guard let itemElement = dockItemElement else { return nil }
        
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(itemElement, kAXTitleAttribute as CFString, &titleValue)
        let title = (titleValue as? String) ?? ""
        
        var itemRect = CGRect.zero
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        if AXUIElementCopyAttributeValue(itemElement, kAXPositionAttribute as CFString, &posVal) == .success,
           AXUIElementCopyAttributeValue(itemElement, kAXSizeAttribute as CFString, &sizeVal) == .success,
           let p = posVal, let s = sizeVal {
            var pt = CGPoint.zero
            var sz = CGSize.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &pt) &&
               AXValueGetValue(s as! AXValue, .cgSize, &sz) {
                let carbonRect = CGRect(origin: pt, size: sz)
                itemRect = DockObserver.cocoaRect(fromCarbonRect: carbonRect)
            }
        }
        
        return DockItemInfo(title: title, rect: itemRect, element: itemElement)
    }
    
    private func handleMouseMoved(screenPoint: NSPoint) {
        let axPoint = carbonCoordinates(from: screenPoint)
        
        // 1. Check if the mouse is directly over a Dock icon
        if let dockItem = findDockItem(at: axPoint),
           let targetApp = findRunningApplication(matching: dockItem.title, dockItemElement: dockItem.element) {
            
            cancelDismissal()
            currentDockItemFrame = dockItem.rect
            
            if currentHoveredPID != targetApp.processIdentifier {
                currentHoveredPID = targetApp.processIdentifier
                let screen = Self.screen(for: dockItem.rect.origin)
                let item = HoveredDockItem(
                    pid: targetApp.processIdentifier,
                    title: targetApp.localizedName ?? dockItem.title,
                    icon: targetApp.icon,
                    frame: dockItem.rect,
                    orientation: self.dockOrientation(for: screen)
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.dockObserver(self, didHoverItem: item)
                }
            }
            return
        }
        
        // 2. Mouse is NOT over a Dock icon.
        // Check if the preview panel is open and visible:
        if let panel = previewPanel, panel.isVisible, panel.alphaValue > 0.05 {
            // (a) Mouse is inside preview panel frame: keep open indefinitely
            if panel.frame.contains(screenPoint) || isMouseInsidePanel {
                cancelDismissal()
                return
            }
            
            // (b) Mouse is within the transit corridor between the dock item and the preview panel
            if let dockFrame = currentDockItemFrame {
                let corridor = transitCorridor(between: dockFrame, and: panel.frame)
                if corridor.contains(screenPoint) {
                    cancelDismissal()
                    return
                }
            }
        }
        
        // 3. Mouse is over the currently hovered dock item rect (with small border buffer)
        if let dockFrame = currentDockItemFrame, currentHoveredPID != nil {
            if dockFrame.insetBy(dx: -8, dy: -8).contains(screenPoint) {
                cancelDismissal()
                return
            }
        }
        
        // 4. Cursor is outside all active areas: schedule dismissal with generous delay
        scheduleDismissal(delay: 0.6)
    }
    
    private func findRunningApplication(matching title: String, dockItemElement: AXUIElement) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        
        // Match by bundle URL if available from AXURLAttribute
        var urlValue: AnyObject?
        if AXUIElementCopyAttributeValue(dockItemElement, "AXURL" as CFString, &urlValue) == .success,
           let url = urlValue as? URL {
            if let match = runningApps.first(where: { $0.bundleURL == url }) {
                return match
            }
        }
        
        guard !title.isEmpty else { return nil }
        
        // Exact match by title
        if let match = runningApps.first(where: { $0.localizedName?.caseInsensitiveCompare(title) == .orderedSame }) {
            return match
        }
        
        // Partial name matching
        if let match = runningApps.first(where: {
            guard let name = $0.localizedName else { return false }
            return name.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(name)
        }) {
            return match
        }
        
        return nil
    }
    
    public func scheduleDismissal(delay: TimeInterval = 0.6) {
        guard currentHoveredPID != nil else { return }
        
        if dismissTimer == nil {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.dismissTimer = nil
                
                let currentMouse = NSEvent.mouseLocation
                
                // Guard 1: Verify mouse is not inside the preview panel
                if let panel = self.previewPanel, panel.isVisible, panel.alphaValue > 0.05 {
                    if panel.frame.insetBy(dx: -4, dy: -4).contains(currentMouse) || self.isMouseInsidePanel {
                        return
                    }
                    
                    // Guard 2: Verify mouse is not inside the transit corridor
                    if let dockFrame = self.currentDockItemFrame {
                        let corridor = self.transitCorridor(between: dockFrame, and: panel.frame)
                        if corridor.contains(currentMouse) {
                            return
                        }
                    }
                }
                
                // Guard 3: Verify mouse is not still hovering the dock item
                if let dockFrame = self.currentDockItemFrame {
                    if dockFrame.insetBy(dx: -8, dy: -8).contains(currentMouse) {
                        return
                    }
                }
                
                // Mouse has truly departed: unhover and dismiss
                self.currentHoveredPID = nil
                self.currentDockItemFrame = nil
                self.isMouseInsidePanel = false
                self.delegate?.dockObserverDidUnhover(self)
            }
        }
    }
    
    public func cancelDismissal() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
    
    public func resetHoverState() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentHoveredPID = nil
        currentDockItemFrame = nil
        isMouseInsidePanel = false
    }
}
