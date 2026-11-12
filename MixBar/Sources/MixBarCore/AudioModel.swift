import Foundation

/// One Core Audio process object: a client process connected to the audio system.
public struct AudioProcess: Equatable {
    public var objectID: UInt32
    public var pid: Int32
    /// As Core Audio reports it; helpers report their own (com.google.Chrome.helper).
    public var bundleIdentifier: String?
    /// The executable's path, used to find the app a helper lives inside.
    public var executablePath: String?
    public var isRunningOutput: Bool
    public init(objectID: UInt32, pid: Int32, bundleIdentifier: String?, executablePath: String? = nil, isRunningOutput: Bool) {
        self.objectID = objectID; self.pid = pid; self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath; self.isRunningOutput = isRunningOutput
    }
}

/// A regular app the user sees in the Dock or the menu bar.
public struct RunningApp: Equatable {
    public var pid: Int32
    public var bundleIdentifier: String
    public var name: String
    /// The .app bundle's path.
    public var bundlePath: String?
    public init(pid: Int32, bundleIdentifier: String, name: String, bundlePath: String? = nil) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.name = name; self.bundlePath = bundlePath
    }
}

/// Every audio process object that belongs to one app, so one slider moves all of them.
public struct AppGroup: Equatable {
    public var bundleIdentifier: String
    public var name: String
    public var processObjectIDs: [UInt32]
    public var isPlaying: Bool
    public init(bundleIdentifier: String, name: String, processObjectIDs: [UInt32], isPlaying: Bool) {
        self.bundleIdentifier = bundleIdentifier; self.name = name
        self.processObjectIDs = processObjectIDs.sorted(); self.isPlaying = isPlaying
    }
}

public struct OutputDevice: Equatable, Identifiable {
    public var uid: String
    public var name: String
    public var id: String { uid }
    public init(uid: String, name: String) { self.uid = uid; self.name = name }
}

public enum AppGrouping {
    /// Groups process objects under the app that owns them, in three steps:
    /// 1. a process running from inside an app's bundle (browser helpers in Contents/Frameworks)
    ///    belongs to the outermost running app at that path;
    /// 2. otherwise one whose bundle identifier extends a running app's (com.google.Chrome.helper)
    ///    belongs to that app;
    /// 3. otherwise a process with its own bundle identifier is its own app.
    /// MixBar's own process (`excludingPID`) and processes without a bundle identifier are
    /// left out: MixBar never taps itself or anything it cannot name and remember.
    public static func group(_ processes: [AudioProcess], apps: [RunningApp], excludingPID: Int32, excludingBundleIdentifier: String) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        var order: [String] = []
        for process in processes where process.pid != excludingPID {
            guard let owner = owner(of: process, apps: apps), owner.bundleIdentifier != excludingBundleIdentifier,
                  !owner.bundleIdentifier.hasPrefix(excludingBundleIdentifier + ".") else { continue }
            if var group = groups[owner.bundleIdentifier] {
                group.processObjectIDs = (group.processObjectIDs + [process.objectID]).sorted()
                group.isPlaying = group.isPlaying || process.isRunningOutput
                groups[owner.bundleIdentifier] = group
            } else {
                order.append(owner.bundleIdentifier)
                groups[owner.bundleIdentifier] = AppGroup(bundleIdentifier: owner.bundleIdentifier, name: owner.name,
                                                          processObjectIDs: [process.objectID], isPlaying: process.isRunningOutput)
            }
        }
        return order.compactMap { groups[$0] }
    }

    static func owner(of process: AudioProcess, apps: [RunningApp]) -> (bundleIdentifier: String, name: String)? {
        if let app = apps.first(where: { $0.pid == process.pid }) {
            let root = outermostApp(containing: app.bundlePath, apps: apps) ?? app
            return (root.bundleIdentifier, root.name)
        }
        if let path = process.executablePath, let app = outermostApp(containing: path, apps: apps) {
            return (app.bundleIdentifier, app.name)
        }
        if let identifier = process.bundleIdentifier {
            // The outermost app: com.google.Chrome.helper.renderer belongs to Chrome, not to its helper.
            let parents = apps.filter { identifier.hasPrefix($0.bundleIdentifier + ".") }
            if let parent = parents.min(by: { $0.bundleIdentifier.count < $1.bundleIdentifier.count }) {
                let root = outermostApp(containing: parent.bundlePath, apps: apps) ?? parent
                return (root.bundleIdentifier, root.name)
            }
            guard BundleIdentifier.isValid(identifier) else { return nil }
            return (identifier, displayName(forBundleIdentifier: identifier, executablePath: process.executablePath))
        }
        return nil
    }

    /// The running app whose bundle holds `path`, choosing the outermost when apps nest.
    static func outermostApp(containing path: String?, apps: [RunningApp]) -> RunningApp? {
        guard let path else { return nil }
        return apps.filter { app in
            guard let bundle = app.bundlePath, !bundle.isEmpty else { return false }
            let prefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
            return path == bundle || path.hasPrefix(prefix)
        }.min { ($0.bundlePath?.count ?? 0) < ($1.bundlePath?.count ?? 0) }
    }

    /// A readable name for a process that is not a regular app: its executable's name,
    /// or the last part of its bundle identifier.
    static func displayName(forBundleIdentifier identifier: String, executablePath: String?) -> String {
        if let path = executablePath, let name = path.split(separator: "/").last, !name.isEmpty { return String(name) }
        return identifier.split(separator: ".").last.map(String.init) ?? identifier
    }
}
