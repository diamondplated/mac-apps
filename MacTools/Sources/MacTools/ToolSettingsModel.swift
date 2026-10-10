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
}

struct BrowserRouteRule: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var domain: String
    var includeSubdomains: Bool = true
    var browserIdentifier: String
    var profileDirectory: String?
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
    @Published var snapshot: ToolSettingsSnapshot?
    @Published var loading = false
    @Published var saving = false
    @Published var message: String?
    @Published var error: String?
    @Published var routeRules: [BrowserRouteRule] = []
    @Published private(set) var savedRouteRules: [BrowserRouteRule] = []
    var hasUnsavedRoutes: Bool { routeRules != savedRouteRules }
    private var requestGeneration = 0

    func synchronizeRouteDraft(_ rules: [BrowserRouteRule]) {
        guard !hasUnsavedRoutes else { return }
        acceptSavedRoutes(rules)
    }

    func acceptSavedRoutes(_ rules: [BrowserRouteRule]) {
        routeRules = rules
        savedRouteRules = rules
    }

    func discardRouteChanges() { routeRules = savedRouteRules }

    func load(_ app: ManagedApp, library: LibraryModel) async {
        guard !saving, !loading, !library.isBusy else { return }
        requestGeneration += 1
        let generation = requestGeneration
        loading = true
        library.operation = "Reading \(app.name) settings…"
        snapshot = nil
        error = nil
        message = nil
        defer {
            if generation == requestGeneration { loading = false }
            library.operation = nil
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

    func save(_ values: [String: Any], app: ManagedApp, library: LibraryModel) async {
        guard !saving, !library.isBusy else { return }
        requestGeneration += 1
        let generation = requestGeneration
        saving = true
        library.operation = "Saving \(app.name) settings…"
        error = nil
        message = nil
        defer { saving = false; library.operation = nil }
        do {
            let patch = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let value = try decode(await library.manager.writeSettings(app, patch: patch), for: app)
            guard generation == requestGeneration, library.settingsApp == app else { return }
            snapshot = value
            message = "Settings saved."
        } catch { self.error = error.localizedDescription }
    }

    func updateShortcut(_ command: String, value: RecordedShortcut?, app: ManagedApp, library: LibraryModel) async {
        do {
            let setting = ToolShortcut(command: command, title: "", shortcut: value)
            let data = try JSONEncoder().encode([setting])
            guard let shortcuts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var item = shortcuts[0]
            if value == nil { item["shortcut"] = NSNull() }
            await save(["shortcuts": [item]], app: app, library: library)
        } catch { self.error = error.localizedDescription }
    }

    private func decode(_ data: Data, for app: ManagedApp) throws -> ToolSettingsSnapshot {
        let snapshot = try JSONDecoder().decode(ToolSettingsSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1, snapshot.app == app.rawValue else {
            throw AppManagerError.message("This app uses an unsupported settings format. Update it and try again.")
        }
        return snapshot
    }
}
