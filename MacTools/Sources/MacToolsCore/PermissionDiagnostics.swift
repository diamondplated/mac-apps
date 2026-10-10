import AppKit
import CoreFoundation
import Foundation

public enum DiagnosticStatus: String, Sendable {
    case passed, attention, notChecked
    public var label: String {
        switch self { case .passed: "Verified"; case .attention: "Needs attention"; case .notChecked: "Not checked" }
    }
}

public struct PermissionFinding: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: DiagnosticStatus
    public let detail: String
    public let settingsPane: String?
}

public struct PermissionReport: Identifiable, Sendable {
    public let app: ManagedApp
    public let installations: [URL]
    public let runningURLs: [URL]
    public let checks: [PermissionFinding]
    public let permissions: [PermissionFinding]
    public let isRunning: Bool
    public let canOpen: Bool
    public var id: String { app.id }
    public var needsAttention: Bool { (checks + permissions).contains { $0.status == .attention } }
}

/// Read-only diagnostics. Permission results come only from the managed app's own
/// versioned CLI; a permission granted to Mac Tools proves nothing about another app.
@MainActor
public enum PermissionDiagnostics {
    public static func inspect(_ app: ManagedApp, manager: AppManager) async -> PermissionReport {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).filter { !$0.isTerminated }
        let runningURLs = Array(Set(running.compactMap(\.bundleURL))).sorted { $0.path < $1.path }
        let discovery = await Task.detached(priority: .utility) {
            discover(app, directories: [InstallScope.system.directoryURL, InstallScope.user.directoryURL])
        }.value
        var checks = discovery.checks
        let installations = discovery.candidates.map(\.url)
        let runningStatus = runningFinding(installations: installations, runningURLs: runningURLs, runningCount: running.count)
        checks.append(runningStatus)
        var bridgeData: Data?
        var signatureValid = false
        if discovery.candidates.count == 1, let candidate = discovery.candidates.first,
           candidate.identifier == app.bundleIdentifier, !candidate.isSymbolicLink {
            do {
                let verification = try await SystemCommand.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", candidate.url.path])
                if verification.status == 0, !verification.truncated {
                    let description = try await SystemCommand.run("/usr/bin/codesign", arguments: ["--display", "--verbose=4", candidate.url.path])
                    let identity = signedIdentifier(description.output + "\n" + description.errorOutput)
                    signatureValid = description.status == 0 && !description.truncated && identity == app.bundleIdentifier
                    checks.append(PermissionFinding(id: "signature", title: "App signature", status: signatureValid ? .passed : .attention,
                        detail: signatureValid ? "The bundle’s code signature is intact and its signed identity matches \(app.name). This check does not establish Apple notarization." : "The signed identity could not be verified as \(app.bundleIdentifier). Reinstall a trusted copy from All Apps.", settingsPane: nil))
                } else {
                    checks.append(PermissionFinding(id: "signature", title: "App signature", status: .attention,
                        detail: "Signature verification failed. Reinstall a trusted copy from All Apps. " + diagnosticMessage(verification.errorOutput), settingsPane: nil))
                }
            } catch {
                checks.append(PermissionFinding(id: "signature", title: "App signature", status: .notChecked, detail: error.localizedDescription, settingsPane: nil))
            }
            if signatureValid {
                do {
                    let data = try await manager.readSettings(app)
                    if validSnapshot(data, app: app) {
                        bridgeData = data
                        checks.append(PermissionFinding(id: "readiness", title: "App connection", status: .passed,
                            detail: "\(app.name)’s own settings command responded. This confirms the app can report settings; it does not prove screen or input access.", settingsPane: nil))
                        if let routing = routingFinding(app, snapshot: data) { checks.append(routing) }
                    } else {
                        checks.append(PermissionFinding(id: "readiness", title: "App connection", status: .attention,
                            detail: "The app returned an unsupported settings response. Update it from All Apps.", settingsPane: nil))
                    }
                } catch {
                    checks.append(PermissionFinding(id: "readiness", title: "App connection", status: .notChecked,
                        detail: error.localizedDescription, settingsPane: nil))
                }
            }
        } else {
            checks.append(PermissionFinding(id: "signature", title: "App signature", status: .notChecked,
                detail: installations.isEmpty ? "Install the app from All Apps to check its signature and settings connection." : "Resolve duplicate copies, symbolic links, or bundle identity conflicts before checking the app.", settingsPane: nil))
        }
        return PermissionReport(app: app, installations: installations, runningURLs: runningURLs,
            checks: checks, permissions: permissionFindings(app, snapshot: bridgeData), isRunning: !running.isEmpty,
            canOpen: discovery.candidates.count == 1 && signatureValid)
    }

    struct Candidate: Sendable {
        let url: URL
        let identifier: String?
        let isSymbolicLink: Bool
    }

    struct Discovery: Sendable {
        let candidates: [Candidate]
        let checks: [PermissionFinding]
    }

    nonisolated static func discover(_ app: ManagedApp, directories: [URL]) -> Discovery {
        var candidates: [Candidate] = []
        var inaccessible: [String] = []
        let manager = FileManager.default
        for directory in directories {
            guard manager.fileExists(atPath: directory.path) else { continue }
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                inaccessible.append("\(directory.path) is a symbolic link and was not inspected.")
                continue
            }
            let entries: [URL]
            do { entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) }
            catch { inaccessible.append("Could not inspect \(directory.path): \(error.localizedDescription)"); continue }
            for url in entries where url.pathExtension.lowercased() == "app" {
                let symbolic = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                let plist = url.appendingPathComponent("Contents/Info.plist")
                let identifier: String?
                if let data = try? Data(contentsOf: plist),
                   let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    identifier = info["CFBundleIdentifier"] as? String
                } else { identifier = nil }
                if url.lastPathComponent.caseInsensitiveCompare(app.payloadFilename) == .orderedSame || identifier == app.bundleIdentifier {
                    candidates.append(Candidate(url: url, identifier: identifier, isSymbolicLink: symbolic))
                }
            }
        }
        candidates.sort { $0.url.path < $1.url.path }
        var checks: [PermissionFinding] = []
        if candidates.isEmpty {
            checks.append(PermissionFinding(id: "installation", title: "Installation", status: .attention,
                detail: "No \(app.name) installation was found directly inside /Applications or ~/Applications.", settingsPane: nil))
        } else if candidates.count > 1 {
            checks.append(PermissionFinding(id: "installation", title: "Installation", status: .attention,
                detail: "\(candidates.count) possible copies were found. Keep one trusted copy, then reopen it; macOS permission entries may refer to a different copy.", settingsPane: nil))
        } else if let candidate = candidates.first {
            let valid = candidate.identifier == app.bundleIdentifier && !candidate.isSymbolicLink
            checks.append(PermissionFinding(id: "installation", title: "Installation", status: valid ? .passed : .attention,
                detail: candidate.isSymbolicLink ? "The installed app path is a symbolic link. Mac Tools manages actual app bundles." :
                    (valid ? "One app with the expected bundle identity was found." : "The app at this path has an unexpected or missing bundle identity. It has not been changed."), settingsPane: nil))
        }
        if !inaccessible.isEmpty {
            checks.append(PermissionFinding(id: "search", title: "Installation search", status: .notChecked,
                detail: inaccessible.joined(separator: "\n"), settingsPane: nil))
        }
        return Discovery(candidates: candidates, checks: checks)
    }

    nonisolated static func runningFinding(installations: [URL], runningURLs: [URL], runningCount: Int) -> PermissionFinding {
        guard runningCount > 0 else {
            return PermissionFinding(id: "running", title: "Running copy", status: .notChecked, detail: "The app is not running. Open it to try its features after reviewing permissions.", settingsPane: nil)
        }
        let installedPaths = Set(installations.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let runningPaths = Set(runningURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let matches = installations.count == 1 && runningCount == 1 && runningURLs.count == 1 && runningPaths == installedPaths
        return PermissionFinding(id: "running", title: "Running copy", status: matches ? .passed : .attention,
            detail: matches ? "The running app matches the installed bundle." : "The running process does not uniquely match the installed copy, or its path could not be determined. Quit extra copies and open the installed app.", settingsPane: nil)
    }

    nonisolated static func validSnapshot(_ data: Data, app: ManagedApp) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["schemaVersion"] as? Int == 1 && json["app"] as? String == app.rawValue
    }

    nonisolated static func permissionFindings(_ app: ManagedApp, snapshot: Data?) -> [PermissionFinding] {
        let requirements: [(String, String, String, String)]
        switch app.rawValue {
        case "dockPeek": requirements = [
            ("accessibility", "Accessibility", "Needed to inspect and switch application windows.", "com.apple.preference.security?Privacy_Accessibility"),
            ("screenRecording", "Screen Recording", "Needed to show live window previews.", "com.apple.preference.security?Privacy_ScreenCapture")]
        case "screenWren": requirements = [
            ("screenRecording", "Screen Recording", "Needed to capture screen content.", "com.apple.preference.security?Privacy_ScreenCapture")]
        case "scrollSplit": requirements = [
            ("accessibility", "Accessibility", "Needed to adjust scrolling events for your devices.", "com.apple.preference.security?Privacy_Accessibility"),
            ("inputMonitoring", "Input Monitoring", "Used to receive input events for scrolling adjustments.", "com.apple.preference.security?Privacy_ListenEvent")]
        default: requirements = []
        }
        var evidence: [String: Any] = [:]
        if let snapshot, validSnapshot(snapshot, app: app),
           let json = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any] {
            evidence = json["permissions"] as? [String: Any] ?? [:]
        }
        return requirements.map { key, title, purpose, pane in
            let allowed: Bool?
            if let number = evidence[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { allowed = number.boolValue }
            else { allowed = nil }
            let status: DiagnosticStatus = allowed.map { $0 ? .passed : .attention } ?? .notChecked
            let result = allowed.map { $0 ? "The app’s own diagnostic process reports access granted. Restart a running copy after changing permissions." : "The app’s own diagnostic process reports access is not granted. Enable \(app.name) in System Settings, then restart it." }
                ?? "This app version does not report its own permission state. Check \(app.name)’s entry in System Settings, then try the feature."
            return PermissionFinding(id: key, title: title, status: status, detail: purpose + " " + result, settingsPane: pane)
        }
    }

    nonisolated static func signedIdentifier(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Identifier=") }.map { String($0.dropFirst("Identifier=".count)) }
    }

    nonisolated static func routingFinding(_ app: ManagedApp, snapshot: Data) -> PermissionFinding? {
        guard app.rawValue == "linkRoutes", validSnapshot(snapshot, app: app),
              let json = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let value = json["isDefaultBrowser"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return PermissionFinding(id: "routing", title: "Default browser", status: value.boolValue ? .passed : .attention,
            detail: value.boolValue ? "LinkRoutes reports that it is the default browser and can receive links for routing." : "LinkRoutes reports that it is not the default browser. Open LinkRoutes and make it the default to route links.", settingsPane: nil)
    }

    nonisolated private static func diagnosticMessage(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }
}
