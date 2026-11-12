import AppKit
import MacToolsCore

struct ToolSettingsSnapshot: Decodable {
    let schemaVersion: Int
    let app: String
    let launchAtLogin: Bool
    let loginStatus: String
    var previewsEnabled: Bool?
    var showsTabs: Bool?
    var dismissalDelay: Double?
    // DockPeek's window switcher and Dock click actions. Absent from older DockPeek builds.
    var switcherEnabled: Bool?
    var dockClickHidesFrontApp: Bool?
    var dockScrollCyclesWindows: Bool?
    var dockMiddleClickOpensWindow: Bool?
    var captureDestination: String?
    var showsThumbnail: Bool?
    var adjustBeforeCapture: Bool?
    var selectionWidth: Int?
    var selectionHeight: Int?
    var aspectRatio: Double?
    var presets: [SizePreset]?
    var shortcuts: [ToolShortcut]?
    var enabled: Bool?
    var reverseVertical: Bool?
    var reverseHorizontal: Bool?
    var speedMultiplier: Double?
    var permissions: [String: Bool]?
    var permissionsSource: String?
    var eventTapStatus: String?

    var hasLiveScrollPermissions: Bool { permissionsSource == "runningApp" }
    /// Whether the app has a permission, or nil when that is not known. Only an answer from
    /// the running app counts. One from the helper process Mac Tools starts describes the
    /// helper, which macOS may attribute to Mac Tools itself.
    func permission(_ key: String) -> Bool? {
        permissionsSource == "runningApp" ? permissions?[key] : nil
    }
    var liveEventTapActive: Bool? { hasLiveScrollPermissions ? permissions?["eventTapActive"] : nil }
    var scrollPermissionContext: String {
        if hasLiveScrollPermissions { return "Reported by the running ScrollSplit app." }
        switch eventTapStatus {
        case "differentCopyRunning": return "A different copy of ScrollSplit is running. Open the installed copy to check its permissions."
        case "ambiguousCopies": return "Multiple copies of ScrollSplit are running. Quit the extra copies, then open the installed app."
        case "notRunning": return "ScrollSplit is not running. Open it to check its permissions."
        default:
            return permissionsSource == "currentProcess"
                ? "These checks came from a diagnostic process. Open ScrollSplit to check permissions for the running app."
                : "Running app permissions are unavailable. Open ScrollSplit to check them."
        }
    }
    var defaultBrowserIdentifier: String?
    var rules: [BrowserRouteRule]?
    var availableBrowsers: [AvailableBrowser]?
    var isDefaultBrowser: Bool?
    // LinkRoutes link cleaning. Absent from older LinkRoutes builds, which also do not
    // understand a rule's source app.
    var stripsTrackingParameters: Bool?
    var unwrapsRedirects: Bool?
    var supportsSourceRules: Bool { stripsTrackingParameters != nil }
}

struct BrowserRouteRule: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var domain: String
    var includeSubdomains: Bool = true
    var browserIdentifier: String
    var profileDirectory: String?
    /// The app the link was clicked in, or nil for any app.
    var sourceBundleIdentifier: String?

    /// LinkRoutes writes "every website" as `*`, and only accepts it on a rule that names a
    /// source app. On screen that is simply an empty website field.
    static let anyWebsite = "*"

    var websiteText: String {
        get { domain == Self.anyWebsite ? "" : domain }
        set { domain = newValue }
    }

    /// The rule as LinkRoutes expects it: an empty website on a rule with a source app
    /// means every website from that app.
    var readyToSave: BrowserRouteRule {
        var rule = self
        rule.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.sourceBundleIdentifier?.isEmpty == true { rule.sourceBundleIdentifier = nil }
        if rule.sourceBundleIdentifier != nil, rule.domain.isEmpty { rule.domain = Self.anyWebsite }
        if rule.sourceBundleIdentifier == nil, rule.domain == Self.anyWebsite { rule.domain = "" }
        return rule
    }
}

struct AvailableBrowser: Decodable, Identifiable {
    let identifier: String
    let name: String
    let profiles: [BrowserProfile]
    var id: String { identifier }
}

struct BrowserProfile: Decodable, Identifiable {
    let directory: String
    let name: String
    var id: String { directory }
}

struct SizePreset: Codable, Equatable, Identifiable {
    var name: String
    var width: Int
    var height: Int
    var id: String { name }
}

struct ToolShortcut: Codable, Identifiable {
    let command: String
    let title: String
    var shortcut: RecordedShortcut?
    var id: String { command }
}

struct RecordedShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let keyLabel: String

    var displayName: String {
        var text = ""
        if carbonModifiers & 4096 != 0 { text += "⌃" }
        if carbonModifiers & 2048 != 0 { text += "⌥" }
        if carbonModifiers & 512 != 0 { text += "⇧" }
        if carbonModifiers & 256 != 0 { text += "⌘" }
        return text + keyLabel
    }
}

@MainActor
final class ToolSettingsModel: ObservableObject {
    @Published var snapshot: ToolSettingsSnapshot? { didSet { synchronizeDrafts() } }
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    /// Why settings could not be read. Failed changes are reported through `LibraryModel.error`.
    @Published var error: String?
    @Published var routeRules: [BrowserRouteRule] = []
    @Published private(set) var savedRouteRules: [BrowserRouteRule] = []
    /// Text and slider drafts live here so they survive the page being rebuilt.
    @Published var selectionWidth = ""
    @Published var selectionHeight = ""
    @Published var presetName = ""
    @Published var scrollSpeed = 1.0
    /// Values the user just chose, shown immediately while the app confirms them.
    @Published private(set) var pending: [String: Any] = [:]
    var hasUnsavedRoutes: Bool { routeRules != savedRouteRules }
    /// True while a read or write may be holding the app manager, including a read that a
    /// newer one has superseded. Installs and other actions wait for this to clear.
    var isUsingManager: Bool { saving || readsInFlight > 0 }
    /// Test seam: stands in for the installed app's settings command.
    var writeOverride: (@MainActor (ManagedApp, Data) async throws -> Data)?
    private var requestGeneration = 0
    private var readsInFlight = 0
    private var saveTail: Task<Bool, Never>?
    private var pendingOwner: [String: Int] = [:]
    private var nextSave = 0

    func synchronizeRouteDraft(_ rules: [BrowserRouteRule]) {
        guard !hasUnsavedRoutes else { return }
        acceptSavedRoutes(rules)
    }

    func acceptSavedRoutes(_ rules: [BrowserRouteRule]) {
        routeRules = rules
        savedRouteRules = rules
    }

    /// Records a finished rules save. Edits made while it was in flight are kept as a new draft.
    func routesSaved(_ saved: [BrowserRouteRule], sent: [BrowserRouteRule]) {
        if routeRules == sent { routeRules = saved }
        savedRouteRules = saved
    }

    func discardRouteChanges() { routeRules = savedRouteRules }

    private func synchronizeDrafts() {
        guard let snapshot else { return }
        selectionWidth = snapshot.selectionWidth.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        selectionHeight = snapshot.selectionHeight.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        scrollSpeed = snapshot.speedMultiplier ?? 1
        if let rules = snapshot.rules { synchronizeRouteDraft(rules) }
    }

    /// Reads an app's settings. A newer request supersedes an older one, so moving between
    /// apps quickly always ends on the app that is showing.
    func load(_ app: ManagedApp, library: LibraryModel) async {
        while saving {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        }
        // The page may have changed while this waited.
        guard !library.isBusy, !Task.isCancelled, library.settingsApp == app else { return }
        requestGeneration += 1
        let generation = requestGeneration
        loading = true
        readsInFlight += 1
        // Keep showing the same app's settings while they refresh; clear another app's.
        if snapshot?.app != app.rawValue { snapshot = nil }
        error = nil
        defer {
            readsInFlight -= 1
            if generation == requestGeneration { loading = false }
        }
        do {
            let value = try decode(await library.manager.readSettings(app), for: app)
            guard generation == requestGeneration, library.settingsApp == app, !Task.isCancelled else { return }
            snapshot = value
        } catch {
            guard generation == requestGeneration, library.settingsApp == app, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Writes one change. Changes are applied strictly in the order they were made.
    @discardableResult
    func save(_ values: [String: Any], app: ManagedApp, library: LibraryModel) async -> Bool {
        await save(app: app, library: library, showing: values) { _ in values }
    }

    /// Writes a change computed from the app's latest saved settings when its turn comes, so
    /// two quick edits to the same list build on each other instead of on the same old copy.
    /// `showing` is displayed at once. `patch` receives the latest snapshot for `app`, or nil
    /// if another app's page is showing by then, and returns nil to write nothing.
    /// Returns whether the app accepted the change.
    @discardableResult
    func save(app: ManagedApp, library: LibraryModel, showing: [String: Any] = [:],
              patch: @escaping (ToolSettingsSnapshot?) -> [String: Any]?) async -> Bool {
        nextSave += 1
        let id = nextSave
        for (key, value) in showing {
            pending[key] = value
            pendingOwner[key] = id
        }
        let previous = saveTail
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            let accepted = await self.write(app: app, library: library, patch: patch)
            // A later change to the same setting keeps its own value on screen.
            for key in showing.keys where self.pendingOwner[key] == id {
                self.pending[key] = nil
                self.pendingOwner[key] = nil
            }
            return accepted
        }
        saveTail = task
        return await task.value
    }

    private func write(app: ManagedApp, library: LibraryModel, patch: (ToolSettingsSnapshot?) -> [String: Any]?) async -> Bool {
        // Wait out a read, or an app being opened or updated. The change is never dropped.
        while loading || library.isBusy {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let values = patch(snapshot?.app == app.rawValue ? snapshot : nil) else { return false }
        requestGeneration += 1
        let generation = requestGeneration
        saving = true
        defer { saving = false }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let result: Data
            if let writeOverride { result = try await writeOverride(app, data) }
            else { result = try await library.manager.writeSettings(app, patch: data) }
            let value = try decode(result, for: app)
            // The write always lands on `app`. Only show the result if its page is still up.
            if generation == requestGeneration, library.settingsApp == app { snapshot = value }
            return true
        } catch {
            library.error = error.localizedDescription
            return false
        }
    }

    func updateShortcut(_ command: String, value: RecordedShortcut?, app: ManagedApp, library: LibraryModel) async {
        do {
            let setting = ToolShortcut(command: command, title: "", shortcut: value)
            let data = try JSONEncoder().encode([setting])
            guard let shortcuts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var item = shortcuts[0]
            if value == nil { item["shortcut"] = NSNull() }
            await save(["shortcuts": [item]], app: app, library: library)
        } catch { library.error = error.localizedDescription }
    }

    private func decode(_ data: Data, for app: ManagedApp) throws -> ToolSettingsSnapshot {
        let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1, snapshot.app == app.rawValue else {
            throw AppManagerError.message("This app uses an unsupported settings format. Update it and try again.")
        }
        return snapshot
    }
}
