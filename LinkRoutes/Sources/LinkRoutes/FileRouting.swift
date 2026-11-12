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

/// A type LinkRoutes has taken over. `fallback` is the app that was the default
/// before, and the app a file of that type opens in when no rule matches.
struct TakenType: Codable, Equatable {
    var fallback: String?
}

/// Everything LinkRoutes keeps about file routing, saved as one value so rules
/// and recorded defaults can never disagree on disk.
struct FileRoutingState: Codable, Equatable {
    var rules: [FileRule] = []
    var taken: [String: TakenType] = [:]
}

/// Stands in for Launch Services. Tests inject a fake; nothing in the pure
/// logic below touches the real defaults.
protocol FileDefaultsService {
    /// Bundle identifier of the app that opens files of this extension by default.
    func defaultApplication(forExtension ext: String) -> String?
    func setDefaultApplication(_ bundleIdentifier: String, forExtension ext: String) throws
    func isInstalled(_ bundleIdentifier: String) -> Bool
    /// Other apps that can open this extension, best first. Used only when a
    /// recorded fallback has disappeared.
    func candidateApplications(forExtension ext: String) -> [String]
}

enum FileDecision: Equatable {
    case open(application: String, usedFallback: Bool)
    case unavailable(String)
}

enum FileRouting {
    static let maximumRules = 100
    static let maximumExtensionLength = 16
    /// Extensions LinkRoutes never takes over: anything that runs code, installs
    /// software or mounts a volume.
    static let blockedExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "csh", "tcsh", "ksh", "fish", "tool", "term", "terminal",
        "pkg", "mpkg", "dmg", "iso", "cdr", "sparseimage", "sparsebundle", "smi",
        "scpt", "scptd", "applescript", "workflow", "action", "wflow", "osax",
        "jar", "exe", "bat", "msi", "dylib", "kext", "plugin", "prefpane", "saver", "xpc", "bundle", "appex", "framework", "service"
    ]

    static func isBlocked(_ ext: String) -> Bool {
        if blockedExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return [UTType.application, .applicationBundle, .unixExecutable, .shellScript, .diskImage].contains { type.conforms(to: $0) }
    }

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
        var result = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// `file` and `folder` must both be resolved already.
    static func contains(folder: String, file: String) -> Bool {
        folder == "/" ? file.hasPrefix("/") : file.hasPrefix(folder + "/")
    }

    static func matches(_ rule: FileRule, extension ext: String, resolvedFile: String, home: String = NSHomeDirectory()) -> Bool {
        guard rule.fileExtension == ext else { return false }
        guard let folder = rule.folder else { return true }
        return contains(folder: resolvedPath(folder, home: home), file: resolvedFile)
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
            normalized[index].fileExtension = try normalizedExtension(rule.fileExtension)
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
            let folderKey = normalized[index].folder.map { resolvedPath($0, home: home) } ?? ""
            guard seen.insert(normalized[index].fileExtension + "|" + folderKey).inserted else {
                throw RouteError.invalid("Two file rules have the same extension and folder.")
            }
        }
        return normalized
    }

    // MARK: Decisions

    /// Picks the app for one file: the first matching rule, else the recorded
    /// fallback. Never LinkRoutes, never an app that is not installed.
    static func decide(file: URL, rules: [FileRule], fallbacks: [String: TakenType], service: FileDefaultsService, home: String = NSHomeDirectory()) -> FileDecision {
        let ext = file.pathExtension.lowercased()
        guard !ext.isEmpty else { return .unavailable("It has no file extension.") }
        guard !isBlocked(ext) else { return .unavailable("LinkRoutes does not open .\(ext) files.") }
        let resolved = resolvedPath(file.path, home: home)
        if let rule = rules.first(where: { matches($0, extension: ext, resolvedFile: resolved, home: home) }),
           rule.applicationIdentifier != applicationIdentifier, service.isInstalled(rule.applicationIdentifier) {
            return .open(application: rule.applicationIdentifier, usedFallback: false)
        }
        if let fallback = fallbacks[ext]?.fallback, fallback != applicationIdentifier, service.isInstalled(fallback) {
            return .open(application: fallback, usedFallback: true)
        }
        // Last resort so nothing fails to open: another installed app for this type, such as the
        // handler of a sibling extension (jpg and jpeg share one type) or when no default was recorded.
        if let other = service.candidateApplications(forExtension: ext).first(where: { $0 != applicationIdentifier && service.isInstalled($0) }) {
            return .open(application: other, usedFallback: true)
        }
        return .unavailable("The app chosen for it, and the app that used to open it, are not available.")
    }
}

// MARK: Taking over and releasing types

enum FileTakeover {
    struct Outcome {
        var state: FileRoutingState
        /// Extensions whose previous default could not be put back.
        var failures: [String]
    }

    /// Moves `state` to `rules`: makes LinkRoutes the default for every extension
    /// that now has a rule (recording the app it replaces) and hands back every
    /// extension that no longer has one. A failure while taking over undoes the
    /// types already changed in this call and throws, leaving everything as it was.
    static func apply(rules: [FileRule], to state: FileRoutingState, service: FileDefaultsService) throws -> Outcome {
        var taken = state.taken
        let wanted = Set(rules.map(\.fileExtension))
        var changed: [(ext: String, previous: String?)] = []
        for ext in wanted.sorted() {
            let current = service.defaultApplication(forExtension: ext)
            if current == applicationIdentifier {
                if taken[ext] == nil { taken[ext] = TakenType(fallback: nil) }
                continue
            }
            do { try service.setDefaultApplication(applicationIdentifier, forExtension: ext) } catch {
                for entry in changed.reversed() { if let previous = entry.previous { try? service.setDefaultApplication(previous, forExtension: entry.ext) } }
                throw RouteError.invalid("macOS did not let LinkRoutes become the default for .\(ext) files. Nothing was changed.")
            }
            changed.append((ext, current))
            // A type the user re-assigned elsewhere is taken again; their new choice becomes the fallback.
            taken[ext] = TakenType(fallback: current)
        }
        var failures: [String] = []
        for ext in taken.keys.sorted() where !wanted.contains(ext) {
            if service.defaultApplication(forExtension: ext) != applicationIdentifier { taken[ext] = nil; continue }
            let recorded = taken[ext]?.fallback
            let replacement = [recorded].compactMap { $0 }.filter { $0 != applicationIdentifier && service.isInstalled($0) }.first
                ?? service.candidateApplications(forExtension: ext).first { $0 != applicationIdentifier && service.isInstalled($0) }
            guard let replacement else { taken[ext] = nil; failures.append(ext); continue }
            do { try service.setDefaultApplication(replacement, forExtension: ext); taken[ext] = nil } catch { failures.append(ext) }
        }
        return Outcome(state: FileRoutingState(rules: rules, taken: taken), failures: failures)
    }

    static func takenOver(_ state: FileRoutingState, service: FileDefaultsService) -> [String] {
        state.taken.keys.filter { service.defaultApplication(forExtension: $0) == applicationIdentifier }.sorted()
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
        let outcome = try FileTakeover.apply(rules: rules, to: load(), service: service)
        try save(outcome.state)
        if !outcome.failures.isEmpty {
            throw PartialRestore(message: "Couldn't put the previous app back for: \(outcome.failures.map { ".\($0)" }.joined(separator: ", ")). Choose one in Finder with Get Info, then Change All.")
        }
    }
    func stopRouting(service: FileDefaultsService) throws { try replace(rules: [], service: service) }
}
