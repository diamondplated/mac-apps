import CoreFoundation
import CryptoKit
import Foundation

/// All methods run away from the main actor. Injectable operations keep tests inside temporary directories.
struct InstallationStore: @unchecked Sendable {
    let payloadDirectory: URL?
    let userDirectory: URL
    let systemDirectory: URL
    var osVersion = ProcessInfo.processInfo.operatingSystemVersion
    var isAppleSilicon = Self.hostIsAppleSilicon
    var verifySignature: @Sendable (URL, ManagedApp) throws -> Void = Self.checkSignature
    var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var removeTransaction: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var settingsTimeout: TimeInterval = 15

    struct Metadata {
        let version: AppVersion
        let minimumOS: String
    }

    func payload(_ app: ManagedApp) throws -> URL {
        guard let payloadDirectory else { throw AppManagerError.message("This copy of Mac Tools has no bundled apps. Build the complete Mac Tools app to install \(app.name).") }
        let url = payloadDirectory.appendingPathComponent(app.payloadFilename)
        guard exists(url) else { throw AppManagerError.message("The bundled \(app.name) app is missing. Rebuild Mac Tools with its app payloads.") }
        return url
    }

    func existing(_ app: ManagedApp) throws -> URL? {
        var matches: [URL] = []
        for directory in [systemDirectory, userDirectory] {
            try rejectSymlink(directory)
            let canonical = directory.appendingPathComponent(app.payloadFilename)
            if exists(canonical) {
                _ = try metadata(canonical, app: app)
                matches.append(canonical)
            }
            // Find renamed copies too, without traversing arbitrary applications.
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" && url != canonical {
                if identifier(url) == app.bundleIdentifier {
                    _ = try metadata(url, app: app)
                    matches.append(url)
                }
            }
        }
        let unique = Array(Set(matches.map { URL(fileURLWithPath: $0.path, isDirectory: false).standardizedFileURL }))
        guard unique.count <= 1 else {
            throw AppManagerError.message("Multiple copies of \(app.name) are installed: \(unique.map(\.path).sorted().joined(separator: ", ")). Move the extra copy to Trash before managing this app.")
        }
        return unique.first
    }

    func metadata(_ url: URL, app: ManagedApp) throws -> Metadata {
        try rejectSymlink(url)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        try rejectSymlink(url.appendingPathComponent("Contents"))
        try rejectSymlink(plist)
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == app.bundleIdentifier else {
            throw AppManagerError.message("\(url.path) is not a valid \(app.name) app. Its bundle identity does not match; it has not been changed.")
        }
        guard info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String,
              executable == app.name,
              let release = info["CFBundleShortVersionString"] as? String, Self.validVersion(release),
              let build = info["CFBundleVersion"] as? String, Self.validVersion(build),
              let minimum = info["LSMinimumSystemVersion"] as? String, Self.validVersion(minimum) else {
            throw AppManagerError.message("\(app.name) has incomplete or invalid app metadata at \(url.path).")
        }
        let executableDirectory = url.appendingPathComponent("Contents/MacOS")
        let executableURL = executableDirectory.appendingPathComponent(executable)
        try rejectSymlink(executableDirectory)
        try rejectSymlink(executableURL)
        guard (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppManagerError.message("\(app.name) has no valid executable at \(executableURL.path).")
        }
        return Metadata(version: AppVersion(release: release, build: build), minimumOS: minimum)
    }

    func isSupported(_ metadata: Metadata, app: ManagedApp) -> Bool {
        unsupportedReason(metadata, app: app) == nil
    }

    /// Why this Mac cannot run the app, or nil when it can. Without metadata only the
    /// app's own floor is checked.
    func unsupportedReason(_ metadata: Metadata?, app: ManagedApp) -> String? {
        if app.requiresAppleSilicon && !isAppleSilicon { return "\(app.name) requires a Mac with Apple silicon." }
        let current = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        if osVersion.majorVersion < app.minimumOSMajor { return "\(app.name) requires macOS \(app.minimumOSMajor) or later." }
        if let metadata, current.compare(metadata.minimumOS, options: .numeric) == .orderedAscending {
            return "\(app.name) requires macOS \(metadata.minimumOS) or later."
        }
        return nil
    }

    // The manager is universal, so this is the slice actually running.
    #if arch(arm64)
    static let hostIsAppleSilicon = true
    #else
    static let hostIsAppleSilicon = false
    #endif

    func validate(_ url: URL, app: ManagedApp) throws -> Metadata {
        let info = try metadata(url, app: app)
        if let reason = unsupportedReason(info, app: app) { throw AppManagerError.message(reason) }
        try verifySignature(url, app)
        return info
    }

    func install(_ app: ManagedApp, scope: InstallScope) throws {
        let source = try payload(app)
        let available = try validate(source, app: app)
        let installed = try existing(app)
        if let installed, available.version < (try metadata(installed, app: app)).version {
            throw AppManagerError.message("The installed \(app.name) is newer than the bundled version. Downgrades are disabled.")
        }
        let target = installed ?? (scope == .user ? userDirectory : systemDirectory).appendingPathComponent(app.payloadFilename)
        let directory = target.deletingLastPathComponent()
        try rejectSymlink(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw AppManagerError.message("Mac Tools cannot write to \(directory.path). Choose Just me for a new installation, or change permissions for the existing app.")
        }
        let transaction = directory.appendingPathComponent(".MacTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = transaction.appendingPathComponent(app.payloadFilename)
        let backup = transaction.appendingPathComponent("Previous.app")
        var backedUp = false
        var placed = false
        do {
            try copy(source, staged)
            _ = try validate(staged, app: app)
            guard try fingerprint(source) == fingerprint(staged) else { throw AppManagerError.message("The staged \(app.name) does not match its bundled source.") }
            // Recheck identity immediately before replacing an existing bundle.
            guard try existing(app) == installed else { throw AppManagerError.message("The installed apps changed during installation. Refresh and try again.") }
            if let installed {
                _ = try metadata(installed, app: app)
                try FileManager.default.moveItem(at: installed, to: backup)
                backedUp = true
            }
            try FileManager.default.moveItem(at: staged, to: target)
            placed = true
            _ = try validate(target, app: app)
            guard try fingerprint(source) == fingerprint(target) else { throw AppManagerError.message("The installed \(app.name) does not match its bundled source.") }
        } catch {
            let originalError = error
            do {
                if placed { try FileManager.default.removeItem(at: target) }
                if backedUp { try FileManager.default.moveItem(at: backup, to: target) }
                try FileManager.default.removeItem(at: transaction)
            } catch {
                throw AppManagerError.message("Installation failed: \(originalError.localizedDescription) Recovery also failed: \(error.localizedDescription). Your previous app is preserved at \(backup.path).")
            }
            throw originalError
        }
        // The verified target stays installed, but a displaced registered bundle
        // must not be left behind silently: removing it later can affect login state.
        do { try removeTransaction(transaction) }
        catch {
            throw AppManagerError.message("\(app.name) was installed successfully, but its previous copy could not be removed at \(transaction.path): \(error.localizedDescription). Remove that recovery folder, then verify launch at login in settings.")
        }
    }

    func uninstall(_ app: ManagedApp) throws {
        guard let target = try existing(app) else { throw AppManagerError.message("\(app.name) is not installed.") }
        _ = try metadata(target, app: app)
        try trash(target)
    }

    func settings(_ app: ManagedApp, patch: Data? = nil) throws -> Data {
        guard app.supportsSettingsBridge else {
            throw AppManagerError.message("\(app.name) keeps its settings in the app. Open \(app.name) to change them.")
        }
        guard let installed = try existing(app) else { throw AppManagerError.message("Install \(app.name) before managing its settings.") }
        _ = try validate(installed, app: app)
        let plistData = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        guard info?["MacToolsSettingsProtocolVersion"] as? Int == 1 else {
            throw AppManagerError.message("This version of \(app.name) does not support settings in Mac Tools. Update the app first.")
        }
        if let patch {
            guard patch.count <= 262_144,
                  (try? JSONSerialization.jsonObject(with: patch)) is [String: Any] else {
                throw AppManagerError.message("The settings update must be a JSON object smaller than 256 KB.")
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let inputURL = temporary.appendingPathComponent("input.json")
        let outputURL = temporary.appendingPathComponent("output.json")
        let errorURL = temporary.appendingPathComponent("error.txt")
        try (patch ?? Data()).write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = installed.appendingPathComponent("Contents/MacOS/\(app.name)")
        process.arguments = ["--mac-tools-settings", patch == nil ? "read" : "write"]
        // Files avoid pipe backpressure even if a helper emits substantial diagnostics.
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(settingsTimeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw AppManagerError.message("\(app.name) did not respond to the settings request. Quit and reopen it, then try again.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let handle = try FileHandle(forReadingFrom: errorURL)
            defer { try? handle.close() }
            let message = String(decoding: try handle.read(upToCount: 16_384) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppManagerError.message("\(app.name) could not \(patch == nil ? "read" : "save") its settings. \(message.isEmpty ? "The settings helper exited with status \(process.terminationStatus)." : message)")
        }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 262_144 else { throw AppManagerError.message("\(app.name) returned an oversized settings response.") }
        let response = try Data(contentsOf: outputURL)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              json["schemaVersion"] as? Int == 1,
              json["app"] as? String == app.rawValue else {
            throw AppManagerError.message("\(app.name) returned an invalid settings response. Update the app and try again.")
        }
        return response
    }

    /// ServiceManagement registration belongs to the bundle on disk, not UserDefaults.
    /// Capture it before moving that bundle and restore only an explicit enabled choice.
    func loginRegistrationToPreserve(_ app: ManagedApp) throws -> Bool {
        guard app.supportsSettingsBridge, let installed = try existing(app) else { return false }
        let data = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        // Older apps have no safe headless endpoint. Never launch their GUI as a probe.
        guard info?["MacToolsSettingsProtocolVersion"] as? Int == 1 else { return false }
        return try Self.loginEnabled(in: settings(app))
    }

    func restoreLoginRegistration(_ app: ManagedApp) throws {
        let response = try settings(app, patch: Data(#"{"launchAtLogin":true}"#.utf8))
        guard try Self.loginEnabled(in: response) else {
            throw AppManagerError.message("\(app.name)'s launch at login registration needs attention. Enable it in the app's settings and approve it in System Settings if requested.")
        }
    }

    static func loginEnabled(in data: Data) throws -> Bool {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["launchAtLogin"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw AppManagerError.message("The app did not report a valid launch at login state.")
        }
        return value.boolValue
    }

    func fingerprint(_ url: URL) throws -> String {
        let manager = FileManager.default
        let root = url.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw AppManagerError.message("Cannot inspect \(url.path).") }
        var paths: [(url: URL, relative: String)] = []
        for case let item as URL in enumerator {
            if item.pathComponents.contains("_CodeSignature") { enumerator.skipDescendants(); continue }
            paths.append((item, item.pathComponents.suffix(enumerator.level).joined(separator: "/")))
        }
        if let enumerationError { throw enumerationError }
        var hash = SHA256()
        for entry in paths.sorted(by: { $0.relative < $1.relative }) {
            let file = entry.url
            let relative = entry.relative
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let resolved = file.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root.path + "/") else {
                    throw AppManagerError.message("The app contains a link outside its bundle: \(relative).")
                }
                hash.update(data: Data((relative + "\0" + (try manager.destinationOfSymbolicLink(atPath: file.path)) + "\0").utf8))
            } else if values.isRegularFile == true {
                hash.update(data: Data((relative + "\0").utf8))
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                hash.update(data: Data([0]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func identifier(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AppManagerError.message("Mac Tools will not manage symbolic links: \(url.path).")
        }
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func checkSignature(_ url: URL, app: ManagedApp) throws {
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        let description = try run("/usr/bin/codesign", ["--display", "--verbose=4", url.path])
        guard description.contains("Identifier=\(app.bundleIdentifier)\n") else {
            throw AppManagerError.message("\(app.name)'s signed identity does not match its bundle identifier.")
        }
        if app == .screenWren && (description.contains("Signature=adhoc") || description.contains("(adhoc)")) {
            throw AppManagerError.message("ScreenWren requires the saved local signing identity. Rebuild it with that identity before installing.")
        }
    }

    private static func run(_ command: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppManagerError.message("Signature verification failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return output
    }
}
