import AppKit
import ApplicationServices
import CoreGraphics

/// Permissions belong to the process macOS attributes them to. The settings CLI runs
/// as a helper of Mac Tools, so its own answer may describe the manager instead of
/// DockPeek. Asking the running DockPeek over a distributed notification gives the
/// answer that matters, and the snapshot says which one it carries.
struct RunningCopy: Equatable {
    let pid: pid_t
    let bundleURL: URL?
}

enum RunningAppPermissions {
    static let statusRequest = Notification.Name("com.andrew.dockpeek.statusRequest")
    static let statusReply = Notification.Name("com.andrew.dockpeek.statusReply")
    static let replyTimeout: TimeInterval = 0.5

    /// The one running copy of this exact bundle, or nil when there is none, a different
    /// copy, or several (in which case no single answer is trustworthy).
    static func soleMatchingCopy(among copies: [RunningCopy], ownURL: URL, ownPID: pid_t) -> RunningCopy? {
        let own = ownURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = copies.filter {
            $0.pid != ownPID && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == own
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Permissions reported by the running app, or nil when it cannot be asked.
    static func report(
        copies: [RunningCopy], ownURL: URL, ownPID: pid_t,
        ask: (pid_t) -> [String: Bool]?
    ) -> [String: Bool]? {
        guard let copy = soleMatchingCopy(among: copies, ownURL: ownURL, ownPID: ownPID) else { return nil }
        return ask(copy.pid)
    }

    /// Only Boolean accessibility and screenRecording values count as a reply.
    static func parse(_ info: [AnyHashable: Any]?, expectedPID: pid_t) -> [String: Bool]? {
        guard let info, (info["pid"] as? NSNumber)?.int32Value == expectedPID,
              let permissions = info["permissions"] as? [String: Bool],
              let accessibility = permissions["accessibility"], let screenRecording = permissions["screenRecording"] else { return nil }
        return ["accessibility": accessibility, "screenRecording": screenRecording]
    }

    /// Live request to the running app, used by the settings CLI.
    static func queryRunningApp() -> [String: Bool]? {
        let identifier = ToolPreferences.bundleIdentifier
        let copies = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == identifier && !$0.isTerminated }
            .map { RunningCopy(pid: $0.processIdentifier, bundleURL: $0.bundleURL) }
        return report(copies: copies, ownURL: Bundle.main.bundleURL, ownPID: ProcessInfo.processInfo.processIdentifier) { pid in
            let token = UUID().uuidString
            var reply: [String: Bool]?
            let center = DistributedNotificationCenter.default()
            let observer = center.addObserver(forName: statusReply, object: token, queue: nil) { notification in
                reply = parse(notification.userInfo, expectedPID: pid)
            }
            defer { center.removeObserver(observer) }
            center.postNotificationName(statusRequest, object: identifier, userInfo: ["token": token], deliverImmediately: true)
            let deadline = Date().addingTimeInterval(replyTimeout)
            while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return reply
        }
    }

    /// Answers requests from the settings CLI with this process's own permissions.
    static func startAnswering() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: statusRequest, object: ToolPreferences.bundleIdentifier, queue: .main
        ) { notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            DistributedNotificationCenter.default().postNotificationName(statusReply, object: token, userInfo: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "permissions": ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()]
            ], deliverImmediately: true)
        }
    }
}
