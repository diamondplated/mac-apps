import Foundation

public struct StartupEntry: Identifiable, Sendable, Equatable {
    public enum TargetStatus: String, Sendable { case present, missing, unresolved }
    public var id: String { fileURL.path }
    public let label: String
    public let fileURL: URL
    public let origin: String
    public let executable: String?
    public let appURL: URL?
    public let targetStatus: TargetStatus
    public let declaredDisabled: Bool
    public let runAtLoad: Bool
    public let keepsAlive: Bool

    public var displayName: String { appURL?.deletingPathExtension().lastPathComponent ?? label }
}

public struct StartupSnapshot: Sendable {
    public let entries: [StartupEntry]
    public let warnings: [String]
    public let backgroundEvidence: String
    public let backgroundAvailable: Bool
    public let collectedAt: Date

    public var evidence: String {
        "Startup Detective — \(collectedAt.formatted())\n\n" + entries.map {
            "\($0.label)\nOrigin: \($0.origin)\nFile: \($0.fileURL.path)\nExecutable: \($0.executable ?? "Not declared")\nTarget: \($0.targetStatus.rawValue)\nDeclared disabled: \($0.declaredDisabled)\n"
        }.joined(separator: "\n") + "\n" + warnings.joined(separator: "\n") + "\n\nBackground registrations\n" + backgroundEvidence
    }
}

public enum StartupDiagnostics {
    public static func parse(data: Data, fileURL: URL, origin: String,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> StartupEntry {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let arguments = plist["ProgramArguments"] as? [String]
        let executable = (plist["Program"] as? String) ?? arguments?.first
        let status: StartupEntry.TargetStatus
        // launchd can resolve a bare command with its own search path. Never call it missing
        // merely because that name is not an absolute filesystem path.
        if let executable, executable.hasPrefix("/") {
            status = exists(executable) ? .present : .missing
        } else { status = .unresolved }
        let appURL = executable.flatMap { applicationURL(forExecutable: $0) }
        let keepAlive: Bool
        if let value = plist["KeepAlive"] as? Bool { keepAlive = value }
        else if let conditions = plist["KeepAlive"] as? [String: Any] { keepAlive = !conditions.isEmpty }
        else { keepAlive = false }
        return StartupEntry(label: label, fileURL: fileURL, origin: origin, executable: executable,
                            appURL: appURL, targetStatus: status,
                            declaredDisabled: plist["Disabled"] as? Bool ?? false,
                            runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepsAlive: keepAlive)
    }

    public static func applicationURL(forExecutable path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // Attribute a nested helper to its outer app, rather than the helper's .app bundle.
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])), isDirectory: true)
    }

    public static func inventory(directories: [(URL, String)]) -> (entries: [StartupEntry], warnings: [String]) {
        var entries: [StartupEntry] = []
        var warnings: [String] = []
        let manager = FileManager.default
        for (directory, origin) in directories {
            guard manager.fileExists(atPath: directory.path) else { continue }
            do {
                let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
                if files.count > 2_000 { warnings.append("\(origin): showing the first 2,000 service files.") }
                for file in files.prefix(2_000) {
                    do {
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 1_048_576 else {
                            warnings.append("\(file.lastPathComponent) is too large to inspect."); continue
                        }
                        entries.append(try parse(data: Data(contentsOf: file), fileURL: file, origin: origin))
                    } catch { warnings.append("Couldn’t read \(file.path): \(error.localizedDescription)") }
                }
            } catch { warnings.append("Couldn’t inspect \(origin): \(error.localizedDescription)") }
        }
        return (entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }, warnings)
    }

    public static func collect() async -> StartupSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories: [(URL, String)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "Your login services"),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "All users’ login services"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System background services"),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), "macOS login services"),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), "macOS background services")
        ]
        let findings = await Task.detached(priority: .utility) { inventory(directories: directories) }.value
        var warnings = findings.warnings
        var background = "macOS background registrations are unavailable."
        var available = false
        do {
            let result = try await SystemCommand.run("/usr/bin/sfltool", arguments: ["dumpbtm"], timeout: 10, maximumOutputBytes: 256_000)
            available = result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if available { background = result.output }
            else { warnings.append("macOS did not provide its background registration list. View Login Items in System Settings for the current switches.") }
            if result.truncated { warnings.append("The background registration list was shortened to keep this inspection responsive.") }
        } catch { warnings.append("Couldn’t read background registrations: \(error.localizedDescription)") }
        return StartupSnapshot(entries: findings.entries, warnings: warnings, backgroundEvidence: background,
                               backgroundAvailable: available, collectedAt: Date())
    }
}
