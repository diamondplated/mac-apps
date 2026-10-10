import AppKit
import SwiftUI
import ServiceManagement

@MainActor final class LinkModel: ObservableObject {
    @Published var browsers: [Browser] = []
    @Published var configuration = Configuration(defaultBrowserIdentifier: "", rules: []) {
        didSet { if !loading { hasUnsavedChanges = true } }
    }
    @Published var hasUnsavedChanges = false
    private var loading = false
    @Published var isDefault = false
    @Published var login = false
    @Published var message = ""
    @Published var busy = false
    @Published var testLink = ""
    @Published var preview = ""
    private var observer: NSObjectProtocol?
    init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(forName: Preferences.changed, object: applicationIdentifier, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    func reload() {
        let snapshot = Preferences.shared.snapshot()
        browsers = snapshot.availableBrowsers
        if !hasUnsavedChanges {
            loading = true
            configuration = Configuration(defaultBrowserIdentifier: snapshot.defaultBrowserIdentifier, rules: snapshot.rules)
            loading = false
        }
        isDefault = snapshot.isDefaultBrowser; login = snapshot.launchAtLogin
    }
    func save() {
        do {
            let data = try JSONEncoder().encode(configuration)
            try Preferences.shared.apply(data: data)
            hasUnsavedChanges = false
            message = "Routing rules saved."; reload()
        } catch { message = error.localizedDescription }
    }
    func setLogin(_ value: Bool) {
        do { try Preferences.shared.apply(data: JSONSerialization.data(withJSONObject: ["launchAtLogin": value])); reload() }
        catch { message = error.localizedDescription; reload() }
    }
    func setDefault(router: Bool) {
        guard !busy else { return }
        let target = router ? Bundle.main.bundleURL : BrowserCatalog.application(configuration.defaultBrowserIdentifier)
        guard let target else { message = "Choose an installed fallback browser first."; return }
        if router {
            do { _ = try Routing.validate(configuration, browsers: browsers); save() }
            catch { message = error.localizedDescription; return }
        }
        busy = true
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: scheme) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                message = router ? "LinkRoutes now routes web links." : "Your fallback browser now opens web links directly."
            } catch { message = "macOS did not complete the default-browser change. You can also change it in System Settings → Desktop & Dock." }
            busy = false; reload()
        }
    }
    func previewRoute() {
        do {
            let url = try Routing.webURL(testLink)
            let config = try Routing.validate(configuration, browsers: browsers)
            guard let target = Routing.target(for: url, configuration: config, browsers: browsers) else { throw RouteError.invalid("No fallback browser is available.") }
            let browser = browsers.first { $0.identifier == target.browserIdentifier }!
            let profile = target.profileDirectory.flatMap { id in browser.profiles.first(where: { $0.directory == id })?.name }
            preview = "\(browser.name)\(profile.map { " · " + $0 } ?? "") · \(target.matchedDomain == nil ? "Fallback" : "Matching rule")"
        } catch { preview = error.localizedDescription }
    }
    func open(_ urls: [URL]) {
        // Incoming traffic always uses saved preferences; editor drafts are never
        // overwritten or activated by a link arriving while settings are open.
        let snapshot = Preferences.shared.snapshot()
        let savedBrowsers = snapshot.availableBrowsers
        let savedConfiguration = Configuration(defaultBrowserIdentifier: snapshot.defaultBrowserIdentifier, rules: snapshot.rules)
        for incoming in urls {
            do {
                let url = try Routing.webURL(incoming.absoluteString)
                guard let target = Routing.target(for: url, configuration: savedConfiguration, browsers: savedBrowsers), let application = BrowserCatalog.application(target.browserIdentifier) else {
                    throw RouteError.invalid("The selected browser or profile is unavailable. Review the matching rule and fallback browser in LinkRoutes.")
                }
                let options = NSWorkspace.OpenConfiguration(); options.activates = true
                if let profile = target.profileDirectory {
                    // Chromium profile arguments are only supported for the explicit
                    // allowlist and never interpolated into a shell command.
                    guard BrowserCatalog.profileRoots[target.browserIdentifier] != nil, Routing.safeProfileDirectory(profile) else { throw RouteError.invalid("The browser profile is unavailable.") }
                    options.createsNewApplicationInstance = true
                    options.arguments = ["--profile-directory=\(profile)", url.absoluteString]
                    NSWorkspace.shared.openApplication(at: application, configuration: options) { _, error in
                        if error != nil { Task { @MainActor in self.message = "The browser could not open this link."; AppDelegate.shared?.showSettings() } }
                    }
                } else {
                    NSWorkspace.shared.open([url], withApplicationAt: application, configuration: options) { _, error in
                        if error != nil { Task { @MainActor in self.message = "The browser could not open this link."; AppDelegate.shared?.showSettings() } }
                    }
                }
            } catch { message = error.localizedDescription; AppDelegate.shared?.showSettings() }
        }
    }
}
struct LinkSettingsView: View {
    @ObservedObject var model: LinkModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 34, weight: .medium)).foregroundStyle(.indigo).frame(width: 64, height: 64).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text("LinkRoutes").font(.largeTitle.bold())
                    Text("The right browser for every link.").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.isDefault ? "Routing links" : "Ready to set up", systemImage: model.isDefault ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(model.isDefault ? .green : .secondary)
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Default browser").font(.headline)
                            Text("LinkRoutes passes each web link to a real browser. Choose where links go when no rule matches.").foregroundStyle(.secondary)
                            Picker("Fallback", selection: $model.configuration.defaultBrowserIdentifier) {
                                ForEach(model.browsers) { browser in Text(browser.name).tag(browser.identifier) }
                            }.frame(maxWidth: 400)
                            HStack {
                                Button(model.isDefault ? "Restore fallback as default" : "Use LinkRoutes for web links") { model.setDefault(router: !model.isDefault) }.disabled(model.busy || model.browsers.isEmpty)
                                Button("System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) }
                                Spacer()
                                Button("Refresh browsers") { model.reload() }
                            }
                            Text("macOS asks you to approve default-browser changes. Restore your fallback before removing LinkRoutes.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text("Routing rules").font(.title2.bold()); Text("First matching rule wins. Profiles are available for Chrome, Edge, and Brave.").foregroundStyle(.secondary) }
                            Spacer()
                            Button { model.configuration.rules.append(RouteRule(domain: "", includeSubdomains: true, browserIdentifier: model.configuration.defaultBrowserIdentifier)) } label: { Label("Add rule", systemImage: "plus") }.disabled(model.browsers.isEmpty)
                        }
                        if model.configuration.rules.isEmpty {
                            VStack(spacing: 8) { Image(systemName: "link").font(.title).foregroundStyle(.indigo); Text("Give your links a destination").font(.headline); Text("Add a domain such as github.com and choose its browser.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(26).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                        }
                        ForEach($model.configuration.rules) { $rule in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        TextField("example.com", text: $rule.domain).textFieldStyle(.roundedBorder)
                                        Button(role: .destructive) { model.configuration.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove rule")
                                    }
                                    HStack {
                                        Toggle("Include subdomains", isOn: $rule.includeSubdomains)
                                        Spacer()
                                        Picker("Browser", selection: $rule.browserIdentifier) { ForEach(model.browsers) { Text($0.name).tag($0.identifier) } }.frame(width: 260).onChange(of: rule.browserIdentifier) { rule.profileDirectory = nil }
                                    }
                                    if let browser = model.browsers.first(where: { $0.identifier == rule.browserIdentifier }), !browser.profiles.isEmpty {
                                        Picker("Profile", selection: Binding(get: { rule.profileDirectory ?? "" }, set: { rule.profileDirectory = $0.isEmpty ? nil : $0 })) {
                                            Text("Browser default").tag("")
                                            ForEach(browser.profiles) { Text($0.name).tag($0.directory) }
                                        }.frame(maxWidth: 420)
                                    }
                                    HStack {
                                        Button("Move up") { move(rule.id, by: -1) }.disabled(model.configuration.rules.first?.id == rule.id)
                                        Button("Move down") { move(rule.id, by: 1) }.disabled(model.configuration.rules.last?.id == rule.id)
                                    }.controlSize(.small)
                                }.padding(8)
                            }
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Try a link").font(.headline)
                            HStack { TextField("https://example.com", text: $model.testLink).textFieldStyle(.roundedBorder); Button("Preview route") { model.previewRoute() } }
                            Text(model.preview.isEmpty ? "Preview uses your current edits. Links and previews are never saved." : model.preview).foregroundStyle(.secondary).font(.callout)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle("Launch at login", isOn: Binding(get: { model.login }, set: { model.setLogin($0) }))
                    Text("macOS starts LinkRoutes when a routed link arrives, even when launch at login is off.").font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }
            Divider()
            HStack {
                Text(model.hasUnsavedChanges ? "Unsaved changes · " + model.message : model.message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("Save changes") { model.save() }.buttonStyle(.borderedProminent).tint(.indigo).keyboardShortcut("s")
            }.padding(20)
        }.frame(minWidth: 760, minHeight: 650)
    }
    func move(_ id: UUID, by offset: Int) {
        guard let index = model.configuration.rules.firstIndex(where: { $0.id == id }), model.configuration.rules.indices.contains(index + offset) else { return }
        model.configuration.rules.swapAt(index, index + offset)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    let model = LinkModel()
    var statusItem: NSStatusItem?
    var window: NSWindow?
    var receivedURL = false
    override init() { super.init(); Self.shared = self }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "LinkRoutes")
        let menu = NSMenu()
        menu.addItem(withTitle: "LinkRoutes Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LinkRoutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu; statusItem = item
        // Initial URL events arrive before or immediately after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !self.receivedURL { self.showSettings() } }
    }
    func application(_ application: NSApplication, open urls: [URL]) { receivedURL = true; model.open(urls) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    @objc func showSettings() {
        if window == nil {
            let view = NSHostingView(rootView: LinkSettingsView(model: model))
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            newWindow.title = "LinkRoutes"; newWindow.contentView = view; newWindow.center(); newWindow.isReleasedWhenClosed = false; window = newWindow
        }
        model.reload(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
