import Cocoa
import ApplicationServices

/// The thin system layer under the layout feature: reading displays and windows, and moving
/// windows through Accessibility. Nothing here raises a window, activates an app or changes Space.
enum LayoutSystem {
    struct AppRef {
        let pid: pid_t
        let bundleID: String
    }

    struct LiveWindow {
        let bundleID: String
        let title: String
        let order: Int
        let frame: CGRect
        let element: AXUIElement
        /// Window-server id; 0 when the app does not expose one.
        let id: UInt32
    }

    /// The connected displays, in top-left global coordinates. Main thread only.
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let raw = ids.prefix(Int(count)).map { id -> RawDisplay in
            let bounds = CGDisplayBounds(id)
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let visible = screen.map { LayoutGeometry.topLeft(fromBottomLeft: $0.visibleFrame, primaryHeight: primaryHeight) } ?? bounds
            return RawDisplay(
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0, frame: bounds, visibleFrame: visible
            )
        }
        return DisplayIdentity.displays(from: raw)
    }

    /// Regular apps other than DockPeek. Main thread only.
    static func runningApps() -> [AppRef] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != own, !app.isTerminated,
                  let bundleID = app.bundleIdentifier else { return nil }
            return AppRef(pid: app.processIdentifier, bundleID: bundleID)
        }
    }

    /// The ordinary windows Accessibility reports for each app (the same ones the switcher
    /// lists), without minimized and full-screen windows. `readable` names the apps that
    /// answered. Safe off the main thread; each app's wait is short.
    static func liveWindows(apps: [AppRef]) -> (windows: [LiveWindow], readable: Set<String>) {
        var windows: [LiveWindow] = []
        var readable = Set<String>()
        var counts: [String: Int] = [:]
        for app in apps {
            guard let list = WindowService.accessibilityWindowsIfReadable(for: app.pid, timeout: 0.25) else { continue }
            readable.insert(app.bundleID)
            for window in list {
                guard WindowFilter.includes(title: window.title, subrole: window.subrole, bounds: window.bounds, isMinimized: window.isMinimized),
                      !window.isMinimized, window.bounds.width > 0, window.bounds.height > 0,
                      !isFullScreen(window.element) else { continue }
                let order = counts[app.bundleID, default: 0]
                counts[app.bundleID] = order + 1
                windows.append(LiveWindow(bundleID: app.bundleID, title: window.title, order: order, frame: window.bounds, element: window.element, id: window.id))
            }
        }
        return (windows, readable)
    }

    private static func isFullScreen(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Moves and resizes a window. Position, size, then position again: an app that clamps the
    /// size to the display it was on leaves the window in the wrong place after the first move.
    @discardableResult
    static func setFrame(_ element: AXUIElement, to frame: CGRect) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        let second = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return first == .success || resized == .success || second == .success
    }

    /// Ids of the ordinary on-screen windows, from the window server alone.
    static func visibleWindowIDs() -> Set<UInt32> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowNumber as String] as? UInt32
        })
    }

    /// A cheap fingerprint of every on-screen window's place, from the window server alone.
    static func onScreenSignature() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [(id: UInt32, frame: CGRect)] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return (number, bounds)
        }
        return WindowSignature.of(windows)
    }
}
