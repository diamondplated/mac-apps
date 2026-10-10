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
    private var requestGeneration = 0

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
