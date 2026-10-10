import Foundation

public enum ManagedApp: String, CaseIterable, Identifiable, Sendable {
    case dockPeek, screenWren, scrollSplit, linkRoutes

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .dockPeek: "DockPeek"
        case .screenWren: "ScreenWren"
        case .scrollSplit: "ScrollSplit"
        case .linkRoutes: "LinkRoutes"
        }
    }
    public var bundleIdentifier: String {
        switch self {
        case .dockPeek: "com.andrew.dockpeek"
        case .screenWren: "io.github.diamondplated.ScreenWren"
        case .scrollSplit: "com.andrew.scrollsplit"
        case .linkRoutes: "com.andrew.linkroutes"
        }
    }
    public var summary: String {
        switch self {
        case .dockPeek: "Preview and switch windows from your Dock."
        case .screenWren: "Capture precisely, annotate, and share your screen."
        case .scrollSplit: "Make mouse scrolling feel right while keeping your trackpad familiar."
        case .linkRoutes: "Open links in the right browser with rules for your favorite sites."
        }
    }
    public var symbolName: String {
        switch self {
        case .dockPeek: "dock.rectangle"
        case .screenWren: "viewfinder"
        case .scrollSplit: "computermouse"
        case .linkRoutes: "arrow.triangle.branch"
        }
    }
    public var minimumOSMajor: Int {
        switch self {
        case .screenWren: 26
        case .dockPeek, .scrollSplit, .linkRoutes: 14
        }
    }
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
