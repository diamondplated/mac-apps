import AppKit
import ServiceManagement

/// Routes incoming links and drives the default-browser flow. All settings live
/// in Mac Tools; this app only needs the saved preferences.
@MainActor final class LinkModel {
    private(set) var isDefault = false
    private(set) var fallbackName = ""
    private(set) var busy = false
    private(set) var takenOverExtensions: [String] = []
    private var observer: NSObjectProtocol?
    var didChange: (() -> Void)?
    /// Called with a reason when a link cannot be opened.
    var onFailure: ((String) -> Void)?
    /// Called with the names of files that could not be opened.
    var onFileFailure: (([String]) -> Void)?

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
        takenOverExtensions = snapshot.takenOverExtensions
        didChange?()
    }

    /// Routes files by the saved file rules. A file with no usable rule opens in
    /// the app that was the default before LinkRoutes took the type over.
    func openFiles(_ files: [URL]) {
        let state = Preferences.shared.fileStore.load()
        let service = LaunchServicesFileDefaults()
        var failed: [String] = []
        for file in files {
            guard case .open(let identifier, _) = FileRouting.decide(file: file, rules: state.rules, fallbacks: state.taken, service: service),
                  let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { failed.append(file.lastPathComponent); continue }
            let options = NSWorkspace.OpenConfiguration(); options.activates = true
            let name = file.lastPathComponent
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: options) { _, error in
                if error != nil { Task { @MainActor in self.onFileFailure?([name]) } }
            }
        }
        if !failed.isEmpty { onFileFailure?(failed) }
    }

    /// Makes LinkRoutes (or the fallback browser) the handler for web links
    /// through the native macOS confirmation. Returns a failure reason, if any.
    func setDefault(router: Bool, completion: @escaping (String?) -> Void) {
        guard !busy else { return }
        let snapshot = Preferences.shared.snapshot()
        let configuration = snapshot.configuration
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

    func open(_ urls: [URL], source: String? = nil) {
        // Incoming traffic always uses saved preferences.
        let snapshot = Preferences.shared.snapshot()
        let savedBrowsers = snapshot.availableBrowsers
        let savedConfiguration = snapshot.configuration
        for incoming in urls {
            do {
                let received = try Routing.webURL(incoming.absoluteString)
                let url = LinkCleaning.clean(received, stripsTracking: savedConfiguration.stripsTrackingParameters, unwrapsRedirects: savedConfiguration.unwrapsRedirects)
                guard let target = Routing.target(for: url, source: source, configuration: savedConfiguration, browsers: savedBrowsers), let application = BrowserCatalog.application(target.browserIdentifier) else {
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
    private var receivedURL = false

    override init() {
        super.init(); Self.shared = self
        // Set before launch finishes: a link can arrive before the status item exists.
        model.onFailure = { [weak self] reason in self?.showFailure(reason) }
        model.onFileFailure = { [weak self] names in self?.showFileFailure(names) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "LinkRoutes")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu; statusItem = item
        rebuildMenu(menu)
        let loginItem = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        offerSetupOnFirstLaunch(launchedAsLoginItem: loginItem)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        // The sender is only available while the delivering Apple Event is current.
        let pid = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let source = LinkSource.bundleIdentifier(processIdentifier: pid) { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { model.openFiles(files) }
        let links = urls.filter { !$0.isFileURL }
        if !links.isEmpty { model.open(links, source: source) }
    }

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
        if !model.takenOverExtensions.isEmpty {
            let shown = model.takenOverExtensions.prefix(3).map { ".\($0)" }.joined(separator: ", ")
            let files = NSMenuItem(title: "Routing Files: \(shown)\(model.takenOverExtensions.count > 3 ? "…" : "")", action: nil, keyEquivalent: "")
            files.isEnabled = false
            menu.addItem(files)
        }
        menu.addItem(.separator())
        let title: String
        if model.isDefault {
            title = model.fallbackName.isEmpty ? "Restore Default Browser…" : "Restore \(model.fallbackName) as Default…"
        } else {
            title = "Make Default Browser…"
        }
        let toggle = menu.addItem(withTitle: title, action: #selector(changeDefault), keyEquivalent: "")
        toggle.target = self
        if !model.takenOverExtensions.isEmpty {
            menu.addItem(withTitle: "Stop Routing Files…", action: #selector(stopRoutingFiles), keyEquivalent: "").target = self
        }
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

    @objc private func stopRoutingFiles() {
        guard !alertShowing else { return }
        alertShowing = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop Routing Files?"
        alert.informativeText = "Each file type goes back to the app that opened it before, and the file rules are removed."
        alert.addButton(withTitle: "Stop Routing Files")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        alertShowing = false
        guard choice == .alertFirstButtonReturn else { return }
        do { try Preferences.shared.stopRoutingFiles() } catch { showFailure(error.localizedDescription, title: "Couldn't Restore Every File Type") }
        model.reload()
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
    func showFailure(_ reason: String, title: String = "Couldn't Open Link") {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = reason
        alert.addButton(withTitle: "Settings…")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    func showFileFailure(_ names: [String]) {
        let listed = names.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        showFailure("\(listed) could not be opened. The app chosen in its file rule, and the app that used to open it, are not available. Review the file rules in Settings.", title: names.count == 1 ? "Couldn't Open File" : "Couldn't Open Files")
    }

    /// Opening the app again is the manager's Open button: offer to make it the
    /// default browser when it is not, and do nothing when it already is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reload()
        offerSetup()
        return false
    }

    /// The one setup alert, shared by reopen and the first launch.
    private func offerSetup() {
        guard !alertShowing, !model.isDefault else { return }
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
    }

    /// Once ever, so an update relaunch or a deliberately-declined app never nags.
    /// Waits briefly so a link that launched the app is routed instead of interrupted.
    private func offerSetupOnFirstLaunch(launchedAsLoginItem: Bool) {
        let defaults = UserDefaults.standard
        let alreadyOffered = defaults.bool(forKey: "hasOfferedSetup")
        defaults.set(true, forKey: "hasOfferedSetup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            model.reload()
            let offer = SetupOffer.shouldOffer(alreadyOffered: alreadyOffered, launchedAsLoginItem: launchedAsLoginItem,
                                               isWorking: model.isDefault, receivedLink: receivedURL)
            if offer { offerSetup() }
        }
    }
}
