import Foundation

public enum ManagedApp: String, CaseIterable, Identifiable, Sendable {
    case dockPeek, screenWren, scrollSplit, linkRoutes, latent, sift

    /// Menu bar utilities run in the background and are configured from Mac Tools.
    /// Apps are ordinary windowed apps that keep their settings to themselves.
    public enum Kind: String, CaseIterable, Sendable {
        case utility, app
        public var title: String { self == .utility ? "Menu Bar Utilities" : "Apps" }
    }

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .dockPeek: "DockPeek"
        case .screenWren: "ScreenWren"
        case .scrollSplit: "ScrollSplit"
        case .linkRoutes: "LinkRoutes"
        case .latent: "Latent"
        case .sift: "Sift"
        }
    }
    public var bundleIdentifier: String {
        switch self {
        case .dockPeek: "com.andrew.dockpeek"
        case .screenWren: "io.github.diamondplated.ScreenWren"
        case .scrollSplit: "com.andrew.scrollsplit"
        case .linkRoutes: "com.andrew.linkroutes"
        case .latent: "com.diamondplated.latent"
        case .sift: "io.github.diamondplated.sift"
        }
    }
    public var kind: Kind {
        switch self {
        case .dockPeek, .screenWren, .scrollSplit, .linkRoutes: .utility
        case .latent, .sift: .app
        }
    }
    /// Whether the app answers `--mac-tools-settings` (MacToolsSettingsProtocolVersion 1).
    /// Mac Tools never runs that command against an app without it.
    public var supportsSettingsBridge: Bool { kind == .utility }
    public var summary: String {
        switch self {
        case .dockPeek: "Preview and switch windows from your Dock."
        case .screenWren: "Capture precisely, annotate, and share your screen."
        case .scrollSplit: "Make mouse scrolling feel right while keeping your trackpad familiar."
        case .linkRoutes: "Open links in the right browser with rules for your favorite sites."
        case .latent: "Browse photo folders fast, cull with the keyboard, and enhance on device."
        case .sift: "Drop in a CSV, Parquet, JSON, or Excel file and explore it instantly."
        }
    }
    public var features: [String] {
        switch self {
        case .dockPeek: ["Live previews", "Window switching", "Browser tabs"]
        case .screenWren: ["Region & window capture", "Markup", "Text recognition"]
        case .scrollSplit: ["Mouse direction", "Wheel speed", "Trackpad preserved"]
        case .linkRoutes: ["Domain rules", "Browser profiles", "Link preview"]
        case .latent: ["Folder browsing", "Vim-style culling", "Local AI enhance"]
        case .sift: ["Huge files", "SQL", "Parquet & Excel"]
        }
    }
    public var onboarding: String {
        switch self {
        case .dockPeek: "Grant Accessibility and Screen Recording, then hover an app in your Dock. Use DockPeek’s menu bar icon for its permission status."
        case .screenWren: "Grant Screen Recording, then capture and annotate from the menu bar. Set shortcuts and launch at login in Tool Settings."
        case .scrollSplit: "Open ScrollSplit to enable scrolling and grant its requested access. Set wheel direction and speed in Tool Settings. Smooth scrolling devices pass through unchanged."
        case .linkRoutes: "Choose browsers and domain rules in Tool Settings. Open LinkRoutes to make it your default link handler when you’re ready."
        case .latent: "Open a folder of photos, or choose Latent in Finder’s Open With menu. Enhancement models are optional; Latent works without them and picks them up from its Application Support folder."
        case .sift: "Drop a data file or folder on Sift’s window or Dock icon, or choose Sift in Finder’s Open With menu. Sift reads files where they are and never uploads them."
        }
    }
    public var symbolName: String {
        switch self {
        case .dockPeek: "dock.rectangle"
        case .screenWren: "viewfinder"
        case .scrollSplit: "computermouse"
        case .linkRoutes: "arrow.triangle.branch"
        case .latent: "photo.on.rectangle.angled"
        case .sift: "tablecells"
        }
    }
    public var minimumOSMajor: Int {
        switch self {
        case .screenWren: 26
        case .dockPeek, .scrollSplit, .linkRoutes, .latent, .sift: 14
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
