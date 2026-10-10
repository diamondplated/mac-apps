import AppKit
import Combine
import MacToolsCore

@MainActor
final class LibraryModel: ObservableObject {
    @Published var states: [ManagedApp: ManagedAppState] = [:]
    @Published var operation: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var scope: InstallScope = .system
    @Published var settingsApp: ManagedApp = .dockPeek
    let manager: AppManager
    private var observers: [AnyCancellable] = []
    private var refreshing = false

    var isBusy: Bool { operation != nil }
    var installedCount: Int { states.values.filter { $0.installedURL != nil }.count }
    var updateCount: Int { states.values.filter(\.isUpdateAvailable).count }

    init() {
        manager = AppManager(payloadDirectory: Bundle.main.resourceURL?.appendingPathComponent("Applications"))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard self?.isBusy == false else { return }
                    Task { await self?.refresh() }
                }
                .store(in: &observers)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.isBusy == false else { return }
                Task { await self?.refresh() }
            }
            .store(in: &observers)
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for app in ManagedApp.allCases { states[app] = await manager.inspect(app) }
    }

    func install(_ app: ManagedApp) async {
        await perform("Installing \(app.name)…", success: "\(app.name) is ready to open.") {
            try await self.manager.install(app, scope: self.scope)
        }
    }

    func installMissing() async {
        await perform("Installing your apps…", success: "Your apps are ready to open.") {
            for app in ManagedApp.allCases {
                let state = await self.manager.inspect(app)
                if state.installedURL == nil, state.payloadAvailable, state.isSupported {
                    try await self.manager.install(app, scope: self.scope)
                }
            }
        }
    }

    func updateAll() async {
        await perform("Updating your apps…", success: "Your apps are up to date.") {
            for app in ManagedApp.allCases {
                let state = await self.manager.inspect(app)
                if state.isUpdateAvailable, state.isSupported { try await self.manager.install(app, scope: self.scope) }
            }
        }
    }

    func launch(_ app: ManagedApp) async {
        await perform("Opening \(app.name)…", success: nil) { try await self.manager.launch(app) }
    }

    func quit(_ app: ManagedApp) async {
        await perform("Quitting \(app.name)…", success: "\(app.name) has quit.") { try await self.manager.quit(app) }
    }

    func uninstall(_ app: ManagedApp) async {
        await perform("Removing \(app.name)…", success: "\(app.name) was moved to the Trash. Your settings were kept.") {
            try await self.manager.uninstall(app)
        }
    }

    func reveal(_ app: ManagedApp) { manager.reveal(app) }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func perform(_ label: String, success: String?, action: () async throws -> Void) async {
        guard !isBusy else { return }
        operation = label
        notice = nil
        defer { operation = nil }
        do {
            try await action()
            notice = success
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
