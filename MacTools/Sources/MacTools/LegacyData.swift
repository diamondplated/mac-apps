import Foundation

/// Mac Tools 1.2 and 1.3 shipped built-in diagnostic pages that have since been removed.
/// This clears the little they stored, so nothing is left behind for a feature that is gone.
enum LegacyData {
    static let preferenceKeys = [
        "hogWatch.watchEnabled", "hogWatch.sampleInterval", "hogWatch.cpuThreshold",
        "startupDetective.showAppleServices",
    ]

    static func remove(defaults: UserDefaults = .standard,
                       applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) {
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        guard let applicationSupport else { return }
        // Folder-size snapshots only. Nothing the user created lives here.
        let baselines = applicationSupport.appendingPathComponent("Mac Tools/Storage Baselines", isDirectory: true)
        try? FileManager.default.removeItem(at: baselines)
    }
}
