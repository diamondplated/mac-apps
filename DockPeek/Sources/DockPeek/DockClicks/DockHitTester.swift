import Cocoa
import ApplicationServices

/// Asks the Dock, and only the Dock, what is under a point. Unlike a system-wide hit
/// test this never waits on whatever app owns the window under the pointer, and the
/// Dock's element carries a short timeout so even a stuck Dock cannot stall input.
final class DockHitTester {
    private static let timeout: Float = 0.1

    private let lock = NSLock()
    private var dockElement: AXUIElement?
    private var appsByURL: [URL: pid_t] = [:]
    private var appsByName: [String: pid_t] = [:]

    /// Refreshes the Dock's process and the running apps. Call on the main thread
    /// whenever apps launch or quit.
    func refresh() {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        let element = dock.map { AXUIElementCreateApplication($0.processIdentifier) }
        if let element { AXUIElementSetMessagingTimeout(element, Self.timeout) }
        var byURL: [URL: pid_t] = [:]
        var byName: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { byURL[url.standardizedFileURL] = app.processIdentifier }
            if let name = app.localizedName?.lowercased(), byName[name] == nil { byName[name] = app.processIdentifier }
        }
        lock.lock()
        dockElement = element
        appsByURL = byURL
        appsByName = byName
        lock.unlock()
    }

    /// One hit test against the Dock. Point in window-server coordinates.
    func hit(at point: CGPoint) -> DockHit? {
        lock.lock()
        let dock = dockElement
        let byURL = appsByURL
        let byName = appsByName
        lock.unlock()
        guard let dock else { return nil }

        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &found) == .success,
              var element = found else { return nil }
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXURLAttribute] as CFArray
        for _ in 0..<3 {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let list = values as? [Any], list.count == 4 else { return nil }
            if (list[0] as? String) == "AXDockItem" {
                let subrole = list[1] as? String ?? ""
                let url = (list[3] as? URL)?.standardizedFileURL
                let title = (list[2] as? String)?.lowercased()
                // Match by bundle URL; the name only when the item reports no URL.
                let pid = url.flatMap { byURL[$0] } ?? (url == nil ? title.flatMap { byName[$0] } : nil)
                return DockHit(subrole: subrole, runningPID: pid)
            }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return nil }
            element = next as! AXUIElement
        }
        return nil
    }
}
