import AppKit
import ServiceManagement

/// Routes incoming links and drives the default-browser flow. All settings live
/// in Mac Tools; this app only needs the saved preferences.
@MainActor final class LinkModel {
    private(set) var isDefault = false
    private(set) var fallbackName = ""
    private(set) var busy = false
    private var observer: NSObjectProtocol?
    var didChange: (() -> Void)?
    /// Called with a reason when a link cannot be opened.
    var onFailure: ((String) -> Void)?

    init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(forName: Preferences.changed, object: applicationIdentifier, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let snapshot = Preferences.shared.snapshot()
        isDefault = snapshot.isDefaultBrowser
        fallbackName = snapshot.availableBrowsers.first { $0.identifier == snapshot.defaultBrowserIdentifier }?.name ?? ""
        didChange?()
    }

    /// Makes LinkRoutes (or the fallback browser) the handler for web links
    /// through the native macOS confirmation. Returns a failure reason, if any.
    func setDefault(router: Bool, completion: @escaping (String?) -> Void) {
        guard !busy else { return }
        let snapshot = Preferences.shared.snapshot()
        let configuration = Configuration(defaultBrowserIdentifier: snapshot.defaultBrowserIdentifier, rules: snapshot.rules)
        let target = router ? Bundle.main.bundleURL : BrowserCatalog.application(configuration.defaultBrowserIdentifier)
        guard let target else { return completion("Choose an installed fallback browser in Settings first.") }
        if router {
            do { _ = try Routing.validate(configuration, browsers: snapshot.availableBrowsers) }
            catch { return completion(error.localizedDescription) }
        }
        busy = true
        Task {
            var failure: String?
            do {
                for scheme in ["http", "https"] {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: scheme) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
            } catch { failure = "macOS did not complete the change. You can also change it in System Settings under Desktop & Dock." }
            busy = false; reload()
            completion(failure)
        }
    }

    func open(_ urls: [URL]) {
        // Incoming traffic always uses saved preferences.
        let snapshot = Preferences.shared.snapshot()
        let savedBrowsers = snapshot.availableBrowsers
        let savedConfiguration = Configuration(defaultBrowserIdentifier: snapshot.defaultBrowserIdentifier, rules: snapshot.rules)
        for incoming in urls {
            do {
                let url = try Routing.webURL(incoming.absoluteString)
                guard let target = Routing.target(for: url, configuration: savedConfiguration, browsers: savedBrowsers), let application = BrowserCatalog.application(target.browserIdentifier) else {
                    throw RouteError.invalid("The selected browser or profile is unavailable. Review the matching rule and fallback browser in Settings.")
                }
                let options = NSWorkspace.OpenConfiguration(); options.activates = true
                let failed: (Error?) -> Void = { error in
                    if error != nil { Task { @MainActor in self.onFailure?("The browser could not open this link.") } }
                }
                if let profile = target.profileDirectory {
                    // Chromium profile arguments are only supported for the explicit
                    // allowlist and never interpolated into a shell command.
                    guard BrowserCatalog.profileRoots[target.browserIdentifier] != nil, Routing.safeProfileDirectory(profile) else { throw RouteError.invalid("The browser profile is unavailable.") }
                    options.createsNewApplicationInstance = true
                    options.arguments = ["--profile-directory=\(profile)", url.absoluteString]
                    NSWorkspace.shared.openApplication(at: application, configuration: options) { _, error in failed(error) }
                } else {
                    NSWorkspace.shared.open([url], withApplicationAt: application, configuration: options) { _, error in failed(error) }
                }
            } catch { onFailure?(error.localizedDescription) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    static let managerIdentifier = "com.andrew.mactools"
    let model = LinkModel()
    var statusItem: NSStatusItem?
    private var alertShowing = false

    override init() {
        super.init(); Self.shared = self
        // Set before launch finishes: a link can arrive before the status item exists.
        model.onFailure = { [weak self] reason in self?.showFailure(reason) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "LinkRoutes")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu; statusItem = item
        rebuildMenu(menu)
    }

    func application(_ application: NSApplication, open urls: [URL]) { model.open(urls) }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        model.reload()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.isDefault ? "Routing Links" : "Not the Default Browser", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let title: String
        if model.isDefault {
            title = model.fallbackName.isEmpty ? "Restore Default Browser…" : "Restore \(model.fallbackName) as Default…"
        } else {
            title = "Make Default Browser…"
        }
        let toggle = menu.addItem(withTitle: title, action: #selector(changeDefault), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LinkRoutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func changeDefault() {
        let router = !model.isDefault
        model.setDefault(router: router) { [weak self] failure in
            if let failure { self?.showFailure(failure) }
        }
    }

    // MARK: Settings

    /// Opens LinkRoutes' page in Mac Tools. Older managers do not answer the
    /// page URL, so fall back to opening the manager, then to an install alert.
    @objc func openSettings() {
        guard let page = URL(string: "mactools://app/linkRoutes") else { return }
        NSWorkspace.shared.open(page, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.openManager() }
        }
    }

    private func openManager() {
        guard let manager = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.managerIdentifier) else { return showInstallAlert() }
        NSWorkspace.shared.openApplication(at: manager, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.showInstallAlert() } }
        }
    }

    private func showInstallAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Mac Tools"
        alert.informativeText = "Mac Tools holds LinkRoutes' settings. Place it in Applications, then open it."
        alert.runModal()
    }

    // MARK: Alerts

    /// Shown when a link cannot be routed.
    func showFailure(_ reason: String) {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't Open Link"
        alert.informativeText = reason
        alert.addButton(withTitle: "Settings…")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    /// Opening the app again is the manager's Open button: offer to make it the
    /// default browser when it is not, and do nothing when it already is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reload()
        guard !alertShowing, !model.isDefault else { return false }
        alertShowing = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LinkRoutes Isn't Your Default Browser"
        alert.informativeText = "Make it the default so web links follow your rules."
        alert.addButton(withTitle: "Make Default Browser…")
        alert.addButton(withTitle: "Not Now")
        let choice = alert.runModal()
        alertShowing = false
        if choice == .alertFirstButtonReturn { changeDefault() }
        return false
    }
}
