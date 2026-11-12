import Foundation

public enum ManagedApp: String, CaseIterable, Identifiable, Sendable {
    case dockPeek, screenWren, scrollSplit, linkRoutes, stayLit, latent, sift

    /// Menu bar utilities run in the background and are configured from Mac Tools.
    /// Apps are ordinary windowed apps that keep their settings to themselves.
    public enum Kind: String, CaseIterable, Sendable {
        case utility, app
        public var title: String { self == .utility ? "Menu Bar" : "Apps" }
    }

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .dockPeek: "DockPeek"
        case .screenWren: "ScreenWren"
        case .scrollSplit: "ScrollSplit"
        case .linkRoutes: "LinkRoutes"
        case .stayLit: "StayLit"
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
        case .stayLit: "com.andrew.staylit"
        case .latent: "com.diamondplated.latent"
        case .sift: "io.github.diamondplated.sift"
        }
    }
    public var kind: Kind {
        switch self {
        case .dockPeek, .screenWren, .scrollSplit, .linkRoutes, .stayLit: .utility
        case .latent, .sift: .app
        }
    }
    /// Whether the app answers `--mac-tools-settings` (MacToolsSettingsProtocolVersion 1).
    /// Mac Tools never runs that command against an app without it.
    public var supportsSettingsBridge: Bool { kind == .utility }
    public var summary: String {
        switch self {
        case .dockPeek: "Preview and switch windows from your Dock, and keep them where you put them."
        case .screenWren: "Capture, record, annotate, and share your screen."
        case .scrollSplit: "Fix the mouse and keyboard: scrolling, buttons, pointer feel, and a few key overrides."
        case .linkRoutes: "Open links and files in the right app, with rules for sites, apps, and folders."
        case .stayLit: "Keep your Mac awake when it matters, and control an external display from the keyboard."
        case .latent: "Browse photo folders fast, cull with the keyboard, group bursts, and enhance on device."
        case .sift: "Drop in a CSV, Parquet, JSON, or Excel file and explore it, or press Space on one in Finder."
        }
    }
    public var onboarding: String {
        switch self {
        case .dockPeek: "Grant Accessibility and Screen Recording, then hover an app in your Dock."
        case .screenWren: "Grant Screen Recording, then capture and annotate from the menu bar."
        case .scrollSplit: "Open ScrollSplit to turn it on and grant the access it asks for. Trackpads and smooth-scrolling mice are left alone."
        case .linkRoutes: "Open LinkRoutes to make it your default browser, then add a rule for each site that belongs somewhere else."
        case .stayLit: "Use StayLit’s menu bar menu to keep your Mac awake now, for a while, or while an app runs. Turn on the display keys here if you use an external monitor."
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
        case .stayLit: "cup.and.saucer"
        case .latent: "photo.on.rectangle.angled"
        case .sift: "tablecells"
        }
    }
    public var minimumOSMajor: Int {
        switch self {
        case .screenWren: 26
        case .dockPeek, .scrollSplit, .linkRoutes, .stayLit, .latent, .sift: 14
        }
    }
    /// Latent's image pipeline stores pixels as Float16, which Swift does not offer on
    /// Intel Macs, so its payload is built for Apple silicon only.
    public var requiresAppleSilicon: Bool { self == .latent }
    public var requirement: String {
        "macOS \(minimumOSMajor) or later" + (requiresAppleSilicon ? " on Apple silicon" : "")
    }
    public var payloadFilename: String { name + ".app" }

    /// The app a `mactools://app/<id>` link points at. Each app's Settings item opens its
    /// page in Mac Tools this way.
    public init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "mactools", url.host?.lowercased() == "app",
              url.pathComponents.count == 2 else { return nil }
        self.init(rawValue: url.pathComponents[1])
    }

    public var deepLink: URL { URL(string: "mactools://app/\(rawValue)")! }
}

public enum InstallScope: String, CaseIterable, Identifiable, Sendable {
    case user, system
    public var id: String { rawValue }
    public var directoryURL: URL {
        self == .user ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications") : URL(fileURLWithPath: "/Applications")
    }
    public var displayName: String { self == .user ? "Only me (~/Applications)" : "All users (/Applications)" }
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
