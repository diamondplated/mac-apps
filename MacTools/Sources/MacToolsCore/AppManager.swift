import AppKit
import Foundation

@MainActor
public final class AppManager {
    private let store: InstallationStore
    private var operationInProgress = false

    public init(payloadDirectory: URL?, userApplicationsDirectory: URL? = nil, systemApplicationsDirectory: URL = URL(fileURLWithPath: "/Applications")) {
        store = InstallationStore(payloadDirectory: payloadDirectory, userDirectory: userApplicationsDirectory ?? InstallScope.user.directoryURL, systemDirectory: systemApplicationsDirectory)
    }

    public func inspect(_ app: ManagedApp) async -> ManagedAppState {
        let running = !runningApplications(app).isEmpty
        let store = store
        return await Task.detached(priority: .utility) {
            var installedURL: URL?
            var installedVersion: String?
            var availableVersion: String?
            var supported = store.osVersion.majorVersion >= app.minimumOSMajor
            var payloadAvailable = false
            var update = false
            var detail = "Ready to install."
            do {
                installedURL = try store.existing(app)
                let installed = try installedURL.map { try store.metadata($0, app: app) }
                installedVersion = installed?.version.release
                let payload = try store.payload(app)
                let available = try store.metadata(payload, app: app)
                availableVersion = available.version.release
                supported = store.isSupported(available, app: app)
                payloadAvailable = true
                if !supported {
                    detail = "Requires macOS \(available.minimumOS) or later."
                } else if let installed, let installedURL {
                    if installed.version > available.version {
                        detail = "A newer version is already installed."
                    } else {
                        update = try available.version > installed.version || (store.fingerprint(payload) != store.fingerprint(installedURL))
                        detail = update ? "A bundled update is ready to install." : "Installed and up to date."
                    }
                }
            } catch {
                detail = error.localizedDescription
            }
            return ManagedAppState(app: app, installedURL: installedURL, installedVersion: installedVersion, availableVersion: availableVersion, isRunning: running, isUpdateAvailable: update, isSupported: supported, payloadAvailable: payloadAvailable, detail: detail)
        }.value
    }

    public func install(_ app: ManagedApp, scope: InstallScope) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        let store = store
        // Reject invalid payloads and downgrades before asking a running app to quit.
        try await Task.detached(priority: .userInitiated) {
            let available = try store.validate(store.payload(app), app: app)
            if let installed = try store.existing(app), available.version < (try store.metadata(installed, app: app)).version {
                throw AppManagerError.message("The installed \(app.name) is newer than the bundled version. Downgrades are disabled.")
            }
        }.value
        let wasRunning = !runningApplications(app).isEmpty
        try await terminateApplications(app)
        try await Self.replaceAndRestoreRunningState(app, wasRunning: wasRunning, replace: {
            try await Task.detached(priority: .userInitiated) { try store.install(app, scope: scope) }.value
        }, reopen: { try await self.openInstalled(app) })
    }

    /// A failed replacement may already have restored the original bundle; restore its running state too.
    static func replaceAndRestoreRunningState(_ app: ManagedApp, wasRunning: Bool,
                                             replace: () async throws -> Void,
                                             reopen: () async throws -> Void) async throws {
        do {
            try await replace()
        } catch {
            let installationError = error
            if wasRunning {
                do { try await reopen() }
                catch {
                    throw AppManagerError.message("\(installationError.localizedDescription) The previous \(app.name) could not be reopened: \(error.localizedDescription)")
                }
            }
            throw installationError
        }
        if wasRunning {
            do { try await reopen() }
            catch {
                throw AppManagerError.message("\(app.name) was installed successfully, but it could not be reopened: \(error.localizedDescription)")
            }
        }
    }

    public func uninstall(_ app: ManagedApp) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        let store = store
        try await Task.detached(priority: .userInitiated) {
            guard try store.existing(app) != nil else { throw AppManagerError.message("\(app.name) is not installed.") }
        }.value
        try await terminateApplications(app)
        try await Task.detached(priority: .userInitiated) { try store.uninstall(app) }.value
    }

    public func launch(_ app: ManagedApp) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await openInstalled(app)
    }

    private func openInstalled(_ app: ManagedApp) async throws {
        let store = store
        let target = try await Task.detached(priority: .userInitiated) {
            guard let target = try store.existing(app) else { throw AppManagerError.message("Install \(app.name) before opening it.") }
            _ = try store.validate(target, app: app)
            return target
        }.value
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
    }

    public func quit(_ app: ManagedApp) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await terminateApplications(app)
    }

    public func reveal(_ app: ManagedApp) {
        let store = store
        Task {
            if let target = try? await Task.detached(priority: .utility, operation: { try store.existing(app) }).value {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }

    public func readSettings(_ app: ManagedApp) async throws -> Data {
        // A selection change may cancel the UI task while its detached read finishes.
        // Queue the next read so it does not publish a transient "busy" error.
        while operationInProgress { try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        try beginOperation()
        defer { operationInProgress = false }
        let store = store
        return try await Task.detached(priority: .userInitiated) { try store.settings(app) }.value
    }

    public func writeSettings(_ app: ManagedApp, patch: Data) async throws -> Data {
        try beginOperation()
        defer { operationInProgress = false }
        let store = store
        return try await Task.detached(priority: .userInitiated) { try store.settings(app, patch: patch) }.value
    }

    private func beginOperation() throws {
        guard !operationInProgress else { throw AppManagerError.message("Another app operation is in progress. Please wait for it to finish.") }
        operationInProgress = true
    }

    private func runningApplications(_ app: ManagedApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).filter { !$0.isTerminated }
    }

    private func terminateApplications(_ app: ManagedApp) async throws {
        let running = runningApplications(app)
        for process in running { _ = process.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while running.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else {
                throw AppManagerError.message("\(app.name) did not quit. Finish any active work, quit it manually, and try again. Its installation has not been changed.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard runningApplications(app).isEmpty else {
            throw AppManagerError.message("\(app.name) restarted while quitting. Quit it manually before continuing.")
        }
    }
}
