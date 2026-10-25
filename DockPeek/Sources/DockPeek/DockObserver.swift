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
    private var hoverCheckTimer: Timer?
    private var dismissalState = HoverDismissalState()
    public var dismissalDelay: TimeInterval = 0.6 {
        didSet { dismissalState = HoverDismissalState(gracePeriod: dismissalDelay) }
    }
    public private(set) var currentHoveredPID: pid_t?
    public private(set) var currentDockItemFrame: CGRect?
    
    private let systemWideElement = AXUIElementCreateSystemWide()
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public func start() {
        stop()
        
        // Listen to global mouse movement across the desktop and dock
        let movementEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: movementEvents) { [weak self] _ in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
        }
        
        // Listen to local mouse movement in our own process windows
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: movementEvents) { [weak self] event in
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
        let hadHover = currentHoveredPID != nil
        resetHoverState()
        if hadHover {
            delegate?.dockObserverDidUnhover(self)
        }
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
            
            dismissalState.reset()
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
                    guard let self = self, self.currentHoveredPID == item.pid else { return }
                    self.delegate?.dockObserver(self, didHoverItem: item)
                }
            }
            startHoverChecks()
            return
        }
        
        recheckPointerPosition()
    }
    
    private func findRunningApplication(matching title: String, dockItemElement: AXUIElement) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        
        // Match by bundle URL if available from AXURLAttribute, then by exact name
        var urlValue: AnyObject?
        let url = AXUIElementCopyAttributeValue(dockItemElement, "AXURL" as CFString, &urlValue) == .success ? urlValue as? URL : nil
        let candidates = runningApps.map { DockItemMatcher.Candidate(name: $0.localizedName, bundleURL: $0.bundleURL) }
        return DockItemMatcher.index(title: title, url: url, in: candidates).map { runningApps[$0] }
    }
    
    /// Recheck actual geometry, including after tracking views are replaced or miss an exit.
    public func recheckPointerPosition() {
        guard currentHoveredPID != nil else { return }

        let panelFrame = previewPanel.flatMap { $0.isVisible ? $0.frame : nil }
        if dismissalState.shouldDismiss(
            pointer: NSEvent.mouseLocation,
            dockFrame: currentDockItemFrame,
            previewFrame: panelFrame,
            now: ProcessInfo.processInfo.systemUptime
        ) {
            resetHoverState()
            delegate?.dockObserverDidUnhover(self)
        }
    }

    private func startHoverChecks() {
        guard hoverCheckTimer == nil else { return }

        // Only sample while a Dock hover is active. This recovers from dropped movement
        // events even if the pointer stops, without polling Accessibility or thumbnails.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.recheckPointerPosition()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        hoverCheckTimer = timer
    }
    
    public func resetHoverState() {
        hoverCheckTimer?.invalidate()
        hoverCheckTimer = nil
        dismissalState.reset()
        currentHoveredPID = nil
        currentDockItemFrame = nil
    }
}
