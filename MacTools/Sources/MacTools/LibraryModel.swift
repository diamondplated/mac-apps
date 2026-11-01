import AppKit
import Combine
import MacToolsCore

@MainActor
final class LibraryModel: ObservableObject {
    @Published var states: [ManagedApp: ManagedAppState] = [:]
    @Published var operation: String?
    @Published var error: String?
    @Published var notice: String? {
        didSet { scheduleNoticeDismissal() }
    }
    /// The app the current operation is acting on, so its card can show progress in place.
    @Published private(set) var activeApp: ManagedApp?
    @Published private(set) var icons: [ManagedApp: NSImage] = [:]
    @Published var scope: InstallScope = .system
    @Published var settingsApp: ManagedApp = .dockPeek
    let toolSettings = ToolSettingsModel()
    let manager: AppManager
    private var observers: [AnyCancellable] = []
    private var refreshing = false
    private var noticeDismissal: Task<Void, Never>?

    var isBusy: Bool { operation != nil }
    var installedCount: Int { states.values.filter { $0.installedURL != nil }.count }
    var updateCount: Int { states.values.filter(\.isUpdateAvailable).count }
    /// Apps that are bundled, supported here, and not installed yet.
    var missingApps: [ManagedApp] {
        ManagedApp.allCases.filter {
            guard let state = states[$0] else { return false }
            return state.installedURL == nil && state.payloadAvailable && state.isSupported
        }
    }

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
        for app in ManagedApp.allCases {
            let state = await manager.inspect(app)
            states[app] = state
            icons[app] = Self.icon(for: app, installedURL: state.installedURL)
        }
    }

    /// The app's own icon, from the installed copy or the bundled one, when it declares one.
    /// Apps without an icon file get a symbol tile in the view instead of the generic app icon.
    private static func icon(for app: ManagedApp, installedURL: URL?) -> NSImage? {
        let payload = Bundle.main.resourceURL?.appendingPathComponent("Applications").appendingPathComponent(app.payloadFilename)
        for url in [installedURL, payload].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            let info = Bundle(url: url)?.infoDictionary
            if (info?["CFBundleIconFile"] as? String)?.isEmpty == false || (info?["CFBundleIconName"] as? String)?.isEmpty == false {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    func install(_ app: ManagedApp) async {
        let updating = states[app]?.installedURL != nil
        await perform(updating ? "Updating \(app.name)…" : "Installing \(app.name)…", app: app,
                      success: updating ? "\(app.name) is up to date." : "\(app.name) is ready to open.") {
            try await self.manager.install(app, scope: self.scope)
        }
    }

    func installMissing() async {
        let apps = missingApps
        await perform("Installing \(ListFormatter.localizedString(byJoining: apps.map(\.name)))…", success: "Your apps are ready to open.") {
            for app in apps {
                let state = await self.manager.inspect(app)
                guard state.installedURL == nil, state.payloadAvailable, state.isSupported else { continue }
                self.activeApp = app
                self.operation = "Installing \(app.name)…"
                try await self.manager.install(app, scope: self.scope)
            }
        }
    }

    func updateAll() async {
        await perform("Updating your apps…", success: "Your apps are up to date.") {
            for app in ManagedApp.allCases {
                let state = await self.manager.inspect(app)
                guard state.isUpdateAvailable, state.isSupported else { continue }
                self.activeApp = app
                self.operation = "Updating \(app.name)…"
                try await self.manager.install(app, scope: self.scope)
            }
        }
    }

    func launch(_ app: ManagedApp) async {
        await perform("Opening \(app.name)…", app: app, success: nil) { try await self.manager.launch(app) }
    }

    func quit(_ app: ManagedApp) async {
        await perform("Quitting \(app.name)…", app: app, success: "\(app.name) has quit.") { try await self.manager.quit(app) }
    }

    func uninstall(_ app: ManagedApp) async {
        await perform("Removing \(app.name)…", app: app, success: "\(app.name) was moved to the Trash. Your settings were kept.") {
            try await self.manager.uninstall(app)
        }
    }

    func reveal(_ app: ManagedApp) { manager.reveal(app) }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func perform(_ label: String, app: ManagedApp? = nil, success: String?, action: () async throws -> Void) async {
        guard !isBusy else { return }
        operation = label
        activeApp = app
        notice = nil
        defer { operation = nil; activeApp = nil }
        do {
            try await action()
            notice = success
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    private func scheduleNoticeDismissal() {
        noticeDismissal?.cancel()
        guard let shown = notice else { return }
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.notice == shown else { return }
            self.notice = nil
        }
    }
}
