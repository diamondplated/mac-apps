import AppKit
import UniformTypeIdentifiers

/// An app a link can come from, for LinkRoutes rules that depend on where a link was clicked.
struct SourceApp: Identifiable, Equatable {
    let identifier: String
    let name: String
    var id: String { identifier }
}

enum SourceApps {
    /// Apps that are open now and could plausibly hand off a link, by name.
    @MainActor
    static func running() -> [SourceApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let identifier = app.bundleIdentifier else { return nil }
            return SourceApp(identifier: identifier, name: app.localizedName ?? identifier)
        }
    }

    /// The choices for one rule: open apps by name, without the excluded ones (LinkRoutes and
    /// Mac Tools never send themselves links), plus the rule's current app if it is not open.
    static func choices(running: [SourceApp], current: String?, excluding: Set<String>,
                        nameFor: (String) -> String) -> [SourceApp] {
        var seen = Set<String>()
        var result = running.filter { !excluding.contains($0.identifier) && seen.insert($0.identifier).inserted }
        if let current, !current.isEmpty, !seen.contains(current) {
            result.append(SourceApp(identifier: current, name: nameFor(current)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A readable name for an app that may not be running, falling back to its identifier.
    static func name(for identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// Apps that can open a kind of file, for LinkRoutes file rules.
enum FileApps {
    /// Apps macOS says can open files with this extension, by name.
    @MainActor
    static func able(toOpen fileExtension: String) -> [SourceApp] {
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).compactMap { url in
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return SourceApp(identifier: identifier, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
    }

    /// A folder as it is shown in a rule: the home folder shortened to `~`.
    static func display(folder: String?, home: String = NSHomeDirectory()) -> String {
        guard let folder, !folder.isEmpty else { return "Any folder" }
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }
}
