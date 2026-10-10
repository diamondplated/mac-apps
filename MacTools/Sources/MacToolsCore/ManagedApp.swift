import Foundation

public enum ManagedApp: String, CaseIterable, Identifiable, Sendable {
    case dockPeek, screenWren

    public var id: String { rawValue }
    public var name: String { self == .dockPeek ? "DockPeek" : "ScreenWren" }
    public var bundleIdentifier: String {
        self == .dockPeek ? "com.andrew.dockpeek" : "io.github.diamondplated.ScreenWren"
    }
    public var summary: String {
        self == .dockPeek ? "Preview and switch windows from your Dock." : "Capture precisely, annotate, and share your screen."
    }
    public var symbolName: String { self == .dockPeek ? "dock.rectangle" : "viewfinder" }
    public var minimumOSMajor: Int { self == .dockPeek ? 14 : 26 }
    public var payloadFilename: String { name + ".app" }
}

public enum InstallScope: String, CaseIterable, Identifiable, Sendable {
    case user, system
    public var id: String { rawValue }
    public var directoryURL: URL {
        self == .user ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications") : URL(fileURLWithPath: "/Applications")
    }
    public var displayName: String { self == .user ? "Just me (~/Applications)" : "All users (/Applications)" }
}

public struct ManagedAppState: Sendable {
    public let app: ManagedApp
    public let installedURL: URL?
    public let installedVersion: String?
    public let availableVersion: String?
    public let isRunning: Bool
    public let isUpdateAvailable: Bool
    public let isSupported: Bool
    public let payloadAvailable: Bool
    public let detail: String
}

public enum AppManagerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct AppVersion: Comparable {
    let release: String
    let build: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        let release = lhs.release.compare(rhs.release, options: .numeric)
        return release == .orderedSame ? lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending : release == .orderedAscending
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.release.compare(rhs.release, options: .numeric) == .orderedSame && lhs.build.compare(rhs.build, options: .numeric) == .orderedSame
    }
}
