import Cocoa
import ApplicationServices

/// One card in the switcher.
struct SwitcherEntry: Identifiable {
    let candidate: SwitcherCandidate
    let appName: String
    let appIcon: NSImage?
    let axElement: AXUIElement?
    var id: String { "\(candidate.pid)-\(candidate.id)-\(candidate.axIndex ?? -1)" }
    var title: String { candidate.title.isEmpty ? appName : candidate.title }

    var windowInfo: WindowInfo {
        WindowInfo(
            id: candidate.id, pid: candidate.pid, title: candidate.title, bounds: .zero,
            thumbnail: nil, appIcon: appIcon, axElement: axElement, isMinimized: candidate.isMinimized
        )
    }
}

/// Lists every window of every regular app, front to back, for the switcher.
enum SwitcherWindowSource {
    private struct App {
        let pid: pid_t
        let name: String
        let icon: NSImage?
    }

    /// Reads the running apps on the main thread, then everything else off it.
    @MainActor
    static func load() async -> [SwitcherEntry] {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated }
            .map { App(pid: $0.processIdentifier, name: $0.localizedName ?? "", icon: $0.icon) }
        return await Task.detached(priority: .userInitiated) { entries(apps: apps, excluding: own) }.value
    }

    private static func entries(apps: [App], excluding own: pid_t) -> [SwitcherEntry] {
        let appsByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let serverWindows: [SwitcherServerWindow] = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, appsByPID[pid] != nil,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { return nil }
            var bounds = CGRect.zero
            if let dictionary = info[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dictionary) ?? .zero
            }
            return SwitcherServerWindow(
                id: number, pid: pid, title: info[kCGWindowName as String] as? String,
                bounds: bounds, isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            )
        }

        // Ask each app in parallel, each with a short timeout, so one stuck app
        // costs at most that timeout instead of holding up the whole panel.
        let pids = apps.map(\.pid)
        var results = [[WindowService.AXWindow]?](repeating: nil, count: pids.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let windows = WindowService.accessibilityWindowsIfReadable(for: pids[index], timeout: 0.25)
            resultsLock.lock()
            results[index] = windows
            resultsLock.unlock()
        }

        var axWindows: [pid_t: [SwitcherAXWindow]] = [:]
        var axElements: [pid_t: [AXUIElement]] = [:]
        var axApps = Set<pid_t>()
        for (index, pid) in pids.enumerated() {
            guard let windows = results[index] else { continue }
            axApps.insert(pid)
            axWindows[pid] = windows.map {
                SwitcherAXWindow(id: $0.id, pid: pid, title: $0.title, subrole: $0.subrole, bounds: $0.bounds, isMinimized: $0.isMinimized)
            }
            axElements[pid] = windows.map(\.element)
        }

        return SwitcherOrdering.order(serverWindows: serverWindows, axWindows: axWindows, axApps: axApps, excluding: own)
            .compactMap { candidate in
                guard let app = appsByPID[candidate.pid] else { return nil }
                let element = candidate.axIndex.flatMap { index in axElements[candidate.pid].flatMap { $0.indices.contains(index) ? $0[index] : nil } }
                return SwitcherEntry(candidate: candidate, appName: app.name, appIcon: app.icon, axElement: element)
            }
    }
}
