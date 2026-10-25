import AppKit

/// Keeps ScreenWren's own ordinary windows out of the way while a capture selector is up.
/// Activating the app for the selector otherwise raises the last editor over the capture target.
@MainActor
final class CaptureWindowClearance {
    private var cleared: [NSWindow] = []
    private var appWasActive = false

    /// Visible, normal-level windows on the current Space, front to back. Pins, panels and
    /// overlays sit at higher levels and stay put.
    static func obstructingWindows(_ orderedWindows: [NSWindow], excluding overlays: [NSWindow]) -> [NSWindow] {
        orderedWindows.filter { window in
            window.isVisible && window.level == .normal && window.isOnActiveSpace
                && !overlays.contains { $0 === window }
        }
    }

    func clear(excluding overlays: [NSWindow], orderedWindows: [NSWindow] = NSApp.orderedWindows,
               appIsActive: Bool = NSApp.isActive) {
        restore(appIsActive: appIsActive)
        appWasActive = appIsActive
        cleared = Self.obstructingWindows(orderedWindows, excluding: overlays)
        cleared.forEach { $0.orderOut(nil) }
    }

    /// Returns cleared windows behind other apps unless ScreenWren was, and still is, frontmost.
    func restore(appIsActive: Bool = NSApp.isActive) {
        let windows = cleared
        cleared = []
        guard !windows.isEmpty else { return }
        if appWasActive && appIsActive {
            for window in windows.reversed() { window.orderFront(nil) }
        } else {
            for window in windows { window.orderBack(nil) }
        }
    }
}
