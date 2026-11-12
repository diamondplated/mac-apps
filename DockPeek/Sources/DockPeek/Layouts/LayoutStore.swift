import Foundation

/// Remembered layouts, one record per arrangement. Holds only bundle identifiers,
/// window titles and frames, and lives in DockPeek's Application Support folder.
struct LayoutStore: Codable, Equatable {
    struct Record: Codable, Equatable {
        var key: String
        var lastUsed: Date
        var windows: [RememberedWindow]
    }

    static let maxArrangements = 20
    static let maxWindowsPerArrangement = 300
    static let maxTitleLength = 200

    var version = 1
    var records: [Record] = []

    func record(for key: String) -> Record? { records.first { $0.key == key } }

    /// Stores the windows for an arrangement and keeps only the most recently used arrangements.
    mutating func set(_ windows: [RememberedWindow], for key: String, now: Date) {
        records.removeAll { $0.key == key }
        records.append(Record(key: key, lastUsed: now, windows: Array(windows.prefix(Self.maxWindowsPerArrangement))))
        trim()
    }

    mutating func touch(_ key: String, now: Date) {
        guard let index = records.firstIndex(where: { $0.key == key }) else { return }
        records[index].lastUsed = now
    }

    mutating func trim() {
        if records.count > Self.maxArrangements {
            records = Array(records.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.maxArrangements))
        }
    }
}

/// Reads and writes the store. A missing or unreadable file is an empty store; the file is
/// readable only by the user.
struct LayoutStoreFile {
    let url: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DockPeek", isDirectory: true).appendingPathComponent("WindowLayouts.json")
    }

    func load() -> LayoutStore {
        guard let data = try? Data(contentsOf: url) else { return LayoutStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var store = try? decoder.decode(LayoutStore.self, from: data), store.version == 1 else {
            // Unreadable (damaged, or from a newer DockPeek): keep it aside rather than overwrite it.
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return LayoutStore()
        }
        store.trim()
        return store
    }

    @discardableResult
    func save(_ store: LayoutStore) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(store) else { return false }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    func forget() {
        try? FileManager.default.removeItem(at: url)
    }
}
