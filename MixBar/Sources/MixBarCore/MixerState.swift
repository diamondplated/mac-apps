import Foundation

/// Edits the mixer makes to an app's setting, and the list of apps it shows.
public enum MixerEditing {
    /// Replaces or adds `entry`. A neutral entry is removed: an app at 100 percent,
    /// unmuted, on System Default has nothing to remember.
    public static func updating(_ list: [AppVolume], with entry: AppVolume) -> [AppVolume] {
        var list = list
        if let index = list.firstIndex(where: { $0.bundleIdentifier == entry.bundleIdentifier }) {
            if entry.isNeutral { list.remove(at: index) } else { list[index] = entry }
        } else if !entry.isNeutral {
            guard list.count < BundleIdentifier.maximumApps else { return list }
            list.append(entry)
        }
        return list
    }

    /// Session choices (used while remembering is off) last only while the app runs.
    public static func pruneSession(_ session: [String: AppVolume], runningBundleIdentifiers: Set<String>) -> [String: AppVolume] {
        session.filter { runningBundleIdentifiers.contains($0.key) }
    }

    public struct Entry: Equatable {
        public var bundleIdentifier: String
        public var name: String
        public var setting: AppVolume
    }

    /// Apps playing sound now (or holding a live tap), plus running apps that have a
    /// setting, sorted by name so rows do not jump while sound starts and stops.
    public static func rows(snapshot: AudioSnapshot, liveBundles: Set<String>, runningApps: [RunningApp],
                            setting: (String) -> AppVolume?) -> [Entry] {
        var entries: [String: Entry] = [:]
        for group in snapshot.groups where group.isPlaying || liveBundles.contains(group.bundleIdentifier) {
            entries[group.bundleIdentifier] = Entry(bundleIdentifier: group.bundleIdentifier, name: group.name,
                                                    setting: setting(group.bundleIdentifier) ?? AppVolume(bundleIdentifier: group.bundleIdentifier, name: group.name))
        }
        for app in runningApps where entries[app.bundleIdentifier] == nil {
            guard let saved = setting(app.bundleIdentifier) else { continue }
            entries[app.bundleIdentifier] = Entry(bundleIdentifier: app.bundleIdentifier, name: app.name, setting: saved)
        }
        return entries.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }
}
