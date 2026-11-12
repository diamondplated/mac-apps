import Foundation
import UniformTypeIdentifiers

/// One rule for files: a file with this extension, optionally inside this folder,
/// opens in the app with this bundle identifier. First match in list order wins.
struct FileRule: Codable, Equatable, Identifiable {
    var id: String
    /// Lowercase, no dot, letters and digits only.
    var fileExtension: String
    /// Absolute path, or starting with `~/`. `nil` matches a file anywhere.
    var folder: String?
    var applicationIdentifier: String
}

/// A content type LinkRoutes has taken over. `fallback` is the app that was the
/// default before, and the app a file of that type opens in when no rule matches.
struct TakenType: Codable, Equatable {
    var fallback: String?
}

/// Everything LinkRoutes keeps about file routing, saved as one value so rules
/// and recorded defaults can never disagree on disk. `taken` is keyed by content
/// type identifier, because macOS assigns a default app per type and one type
/// covers several extensions (jpg and jpeg).
struct FileRoutingState: Codable, Equatable {
    var rules: [FileRule] = []
    var taken: [String: TakenType] = [:]
}

/// Stands in for Launch Services. Tests inject a fake; nothing in the pure
/// logic below touches the real defaults.
protocol FileDefaultsService {
    /// The declared content type an extension resolves to, or `nil` when it has none.
    func typeIdentifier(forExtension ext: String) -> String?
    /// Bundle identifier of the app that opens this type by default.
    func defaultApplication(forType type: String) -> String?
    func setDefaultApplication(_ bundleIdentifier: String, forType type: String) throws
    func isInstalled(_ bundleIdentifier: String) -> Bool
    /// Other apps that can open this type, best first. Used only when a
    /// recorded fallback has disappeared.
    func candidateApplications(forType type: String) -> [String]
    /// The file system's own canonical spelling of an existing path (on-disk case),
    /// or `nil` when the path does not exist.
    func canonicalPath(_ path: String) -> String?
}

enum FileDecision: Equatable {
    case open(application: String, usedFallback: Bool)
    case unavailable(String)
}

enum FileRouting {
    static let maximumRules = 100
    static let maximumExtensionLength = 16
    /// Extensions LinkRoutes never takes over, by name. Backed by a check on the
    /// type itself, so the block does not depend on this list being complete.
    static let blockedExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "csh", "tcsh", "ksh", "fish", "tool", "term", "terminal",
        "pkg", "mpkg", "dmg", "iso", "cdr", "sparseimage", "sparsebundle", "smi",
        "scpt", "scptd", "applescript", "workflow", "action", "wflow", "osax",
        "jar", "exe", "bat", "msi", "dylib", "kext", "plugin", "prefpane", "saver", "xpc", "bundle", "appex", "framework", "service"
    ]
    /// Types that are applications, native executables, installer packages or disk images.
    static let blockedTypes: [UTType] = [
        .application, .applicationBundle, .unixExecutable, .diskImage,
        UTType("com.apple.installer-package-archive"), UTType("com.apple.installer-package"), UTType("com.apple.application-bundle")
    ].compactMap { $0 }

    /// Ordinary scripts and source files are allowed on purpose.
    static func isBlockedByType(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return false }
        return blockedTypes.contains { type.conforms(to: $0) }
    }
    static func isBlocked(_ ext: String) -> Bool { blockedExtensions.contains(ext) || isBlockedByType(ext) }

    static func normalizedExtension(_ text: String) throws -> String {
        let ext = text.lowercased()
        guard !ext.isEmpty, ext.utf8.count <= maximumExtensionLength,
              ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw RouteError.invalid("A file rule needs an extension of letters and digits, such as md, without the dot.")
        }
        guard !isBlocked(ext) else {
            throw RouteError.invalid("LinkRoutes does not take over .\(ext) files, because they run code or mount disks.")
        }
        return ext
    }

    // MARK: Paths

    /// Expands `~`, resolves symbolic links and `..`, and drops a trailing slash,
    /// so two spellings of one place compare equal.
    static func resolvedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path
        if path == "~" { expanded = home } else if path.hasPrefix("~/") { expanded = home + String(path.dropFirst(1)) }
        return stripTrailingSlashes(URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path)
    }
    private static func stripTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
    /// The path both sides of a comparison use: resolved, then spelled the way the
    /// volume spells it (so `~/notes` and `~/Notes` agree on a case-insensitive
    /// volume). A path that does not exist yet stays as resolved.
    static func comparablePath(_ path: String, service: FileDefaultsService, home: String = NSHomeDirectory()) -> String {
        let resolved = resolvedPath(path, home: home)
        return service.canonicalPath(resolved).map(stripTrailingSlashes) ?? resolved
    }

    /// `file` and `folder` must both be comparable paths already.
    static func contains(folder: String, file: String) -> Bool {
        folder == "/" ? file.hasPrefix("/") : file.hasPrefix(folder + "/")
    }

    static func matches(_ rule: FileRule, extension ext: String, comparableFile: String, service: FileDefaultsService, home: String = NSHomeDirectory()) -> Bool {
        guard rule.fileExtension == ext else { return false }
        guard let folder = rule.folder else { return true }
        return contains(folder: comparablePath(folder, service: service, home: home), file: comparableFile)
    }

    // MARK: Validation

    /// Validates the whole list before anything is written or any default changes.
    static func validate(_ rules: [FileRule], service: FileDefaultsService, home: String = NSHomeDirectory()) throws -> [FileRule] {
        guard rules.count <= maximumRules else { throw RouteError.invalid("File rules are limited to \(maximumRules).") }
        guard Set(rules.map(\.id)).count == rules.count else { throw RouteError.invalid("File rules must have unique identifiers.") }
        var normalized = rules
        var seen = Set<String>()
        for index in normalized.indices {
            let rule = normalized[index]
            guard !rule.id.isEmpty, rule.id.utf8.count <= 64, !rule.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RouteError.invalid("A file rule has an invalid identifier.")
            }
            let ext = try normalizedExtension(rule.fileExtension)
            normalized[index].fileExtension = ext
            guard service.typeIdentifier(forExtension: ext) != nil else {
                throw RouteError.invalid("macOS has no file type for .\(ext), so LinkRoutes cannot take it over reliably.")
            }
            if let folder = rule.folder {
                let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.utf8.count <= 1024, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"),
                      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw RouteError.invalid("A file rule's folder must be an absolute path or start with ~/.")
                }
                var path = trimmed
                while path.count > 1, path.hasSuffix("/"), path != "~/" { path.removeLast() }
                normalized[index].folder = path
            }
            let identifier = rule.applicationIdentifier
            guard !identifier.isEmpty, identifier.utf8.count <= 255,
                  identifier.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_") }) else {
                throw RouteError.invalid("A file rule has an invalid app.")
            }
            guard identifier != applicationIdentifier else { throw RouteError.invalid("A file rule cannot open files with LinkRoutes itself.") }
            guard service.isInstalled(identifier) else { throw RouteError.invalid("A file rule refers to an app that is not installed.") }
            let folderKey = normalized[index].folder.map { comparablePath($0, service: service, home: home) } ?? ""
            guard seen.insert(ext + "|" + folderKey).inserted else {
                throw RouteError.invalid("Two file rules have the same extension and folder.")
            }
        }
        return normalized
    }

    // MARK: Decisions

    /// Picks the app for one file: the first matching rule, else the recorded
    /// fallback for the file's type whatever its extension. Never LinkRoutes,
    /// never an app that is not installed.
    static func decide(file: URL, rules: [FileRule], fallbacks: [String: TakenType], service: FileDefaultsService, home: String = NSHomeDirectory()) -> FileDecision {
        let ext = file.pathExtension.lowercased()
        guard !ext.isEmpty else { return .unavailable("It has no file extension.") }
        guard !isBlocked(ext) else { return .unavailable("LinkRoutes does not open .\(ext) files.") }
        let comparable = comparablePath(file.path, service: service, home: home)
        if let rule = rules.first(where: { matches($0, extension: ext, comparableFile: comparable, service: service, home: home) }),
           rule.applicationIdentifier != applicationIdentifier, service.isInstalled(rule.applicationIdentifier) {
            return .open(application: rule.applicationIdentifier, usedFallback: false)
        }
        guard let type = service.typeIdentifier(forExtension: ext) else { return .unavailable("macOS has no file type for it.") }
        if let fallback = fallbacks[type]?.fallback, fallback != applicationIdentifier, service.isInstalled(fallback) {
            return .open(application: fallback, usedFallback: true)
        }
        // Last resort so nothing fails to open: another installed app for this type.
        if let other = service.candidateApplications(forType: type).first(where: { $0 != applicationIdentifier && service.isInstalled($0) }) {
            return .open(application: other, usedFallback: true)
        }
        return .unavailable("The app chosen for it, and the app that used to open it, are not available.")
    }
}

// MARK: Taking over and releasing types

enum FileTakeover {
    struct Outcome {
        var state: FileRoutingState
        /// Types whose previous default could not be put back.
        var failures: [String]
    }

    static func types(of rules: [FileRule], service: FileDefaultsService) -> Set<String> {
        Set(rules.compactMap { service.typeIdentifier(forExtension: $0.fileExtension) })
    }

    /// Moves `state` to `rules`. Every type that now has a rule for any of its
    /// extensions is taken over once (recording the app it replaces) and every type
    /// left with no rule for any extension is handed back. The record is written
    /// through `persist` before the system is asked to change a default and removed
    /// only if the change is refused, so an interruption leaves at worst a harmless
    /// record. A refusal undoes the types already changed in this call and throws.
    static func apply(rules: [FileRule], to state: FileRoutingState, service: FileDefaultsService,
                      persist: (FileRoutingState) throws -> Void = { _ in }) throws -> Outcome {
        var taken = state.taken
        let wanted = types(of: rules, service: service)
        var changed: [(type: String, previous: String?, record: TakenType?)] = []
        func rollBack() {
            for entry in changed.reversed() {
                if let previous = entry.previous { try? service.setDefaultApplication(previous, forType: entry.type) }
                taken[entry.type] = entry.record
            }
            try? persist(FileRoutingState(rules: state.rules, taken: taken))
        }
        for type in wanted.sorted() {
            let current = service.defaultApplication(forType: type)
            if current == applicationIdentifier {
                if taken[type] == nil { taken[type] = TakenType(fallback: nil) }
                continue
            }
            let before = taken[type]
            // A type the user re-assigned elsewhere is taken again; their new choice becomes the fallback.
            taken[type] = TakenType(fallback: current)
            changed.append((type, current, before))
            do {
                try persist(FileRoutingState(rules: state.rules, taken: taken))
                try service.setDefaultApplication(applicationIdentifier, forType: type)
            } catch {
                // The refused type itself has no previous change to undo, only its record.
                taken[type] = before
                changed.removeLast()
                try? persist(FileRoutingState(rules: state.rules, taken: taken))
                rollBack()
                throw RouteError.invalid("macOS did not let LinkRoutes become the default for \(type) files. Nothing was changed.")
            }
        }
        var failures: [String] = []
        for type in taken.keys.sorted() where !wanted.contains(type) {
            // Includes a record left by an interrupted take-over: if LinkRoutes never became
            // the default there is nothing to restore.
            if service.defaultApplication(forType: type) != applicationIdentifier { taken[type] = nil; continue }
            let recorded = taken[type]?.fallback
            let replacement = [recorded].compactMap { $0 }.filter { $0 != applicationIdentifier && service.isInstalled($0) }.first
                ?? service.candidateApplications(forType: type).first { $0 != applicationIdentifier && service.isInstalled($0) }
            guard let replacement else { taken[type] = nil; failures.append(type); continue }
            do { try service.setDefaultApplication(replacement, forType: type); taken[type] = nil } catch { failures.append(type) }
        }
        return Outcome(state: FileRoutingState(rules: rules, taken: taken), failures: failures)
    }

    /// Types LinkRoutes currently owns: recorded and actually the default.
    static func ownedTypes(_ state: FileRoutingState, service: FileDefaultsService) -> [String] {
        state.taken.keys.filter { service.defaultApplication(forType: $0) == applicationIdentifier }.sorted()
    }

    /// The extensions that have rules and whose type LinkRoutes owns.
    static func takenOver(_ state: FileRoutingState, service: FileDefaultsService) -> [String] {
        let owned = Set(ownedTypes(state, service: service))
        return Set(state.rules.map(\.fileExtension).filter { ext in service.typeIdentifier(forExtension: ext).map(owned.contains) ?? false }).sorted()
    }
}

/// The new state was saved, but some previous defaults could not be put back.
struct PartialRestore: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Saves file-routing state in preferences.
struct FileRoutingStore {
    static let key = "fileRoutingState"
    let defaults: UserDefaults

    func load() -> FileRoutingState {
        defaults.synchronize()
        guard let data = defaults.data(forKey: Self.key), let state = try? JSONDecoder().decode(FileRoutingState.self, from: data) else { return FileRoutingState() }
        return state
    }
    func save(_ state: FileRoutingState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: Self.key)
        defaults.synchronize()
    }
    /// Applies already-validated rules. The new state is saved even when some
    /// defaults could not be restored, so recorded fallbacks keep working, and
    /// the failure is then reported.
    func replace(rules: [FileRule], service: FileDefaultsService) throws {
        let outcome = try FileTakeover.apply(rules: rules, to: load(), service: service, persist: save)
        try save(outcome.state)
        if !outcome.failures.isEmpty {
            throw PartialRestore(message: "Couldn't put the previous app back for: \(outcome.failures.joined(separator: ", ")). Choose one in Finder with Get Info, then Change All.")
        }
    }
    func stopRouting(service: FileDefaultsService) throws { try replace(rules: [], service: service) }
}
