import AppKit
import Foundation
import ServiceManagement

final class BrowserCatalog {
    // URL-handler registration alone also discovers link routers and helper apps.
    // Explicit browser identities keep fallback routing out of those loops.
    static let supportedIdentifiers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "com.kagi.kagimacOS", "app.zen-browser.zen"
    ]
    static let profileRoots = ["com.google.Chrome": "Google/Chrome", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "BraveSoftware/Brave-Browser"]
    static func application(_ identifier: String) -> URL? {
        guard supportedIdentifiers.contains(identifier), identifier != applicationIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier,
              let declarations = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              declarations.contains(where: { declaration in
                  let schemes = (declaration["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() }
                  return schemes.contains("http") || schemes.contains("https")
              }) else { return nil }
        return url
    }
    static func browsers() -> [Browser] {
        let workspace = NSWorkspace.shared
        let urls = workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id), application(id) != nil else { return nil }
            seen.insert(id)
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            var profiles: [BrowserProfile] = []
            if let relative = profileRoots[id] {
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(relative)
                let state = root.appendingPathComponent("Local State")
                if let size = try? state.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_388_608, let data = try? Data(contentsOf: state) { profiles = Routing.profiles(data: data, root: root) }
            }
            return Browser(identifier: id, name: name, profiles: profiles)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func systemDefault() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
    static var isDefault: Bool {
        ["http", "https"].contains { scheme in
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier } == applicationIdentifier
        }
    }
}
struct SettingsSnapshot: Encodable {
    let schemaVersion = 1
    let app = "linkRoutes"
    let launchAtLogin: Bool
    let loginStatus: String
    let defaultBrowserIdentifier: String
    let rules: [RouteRule]
    let availableBrowsers: [Browser]
    let isDefaultBrowser: Bool
}
struct SettingsPatch {
    var configuration: Configuration
    var launchAtLogin: Bool?
    init(data: Data, current: Configuration, browsers: [Browser]) throws {
        guard data.count <= 262_144, let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(values.keys).isSubset(of: ["launchAtLogin", "defaultBrowserIdentifier", "rules"]) else { throw RouteError.invalid("Unknown or read-only setting, or oversized patch.") }
        if let value = values["launchAtLogin"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RouteError.invalid("launchAtLogin must be a Boolean.") }
            launchAtLogin = number.boolValue
        }
        var config = current
        if let value = values["defaultBrowserIdentifier"] {
            guard let identifier = value as? String else { throw RouteError.invalid("defaultBrowserIdentifier must be a string.") }
            config.defaultBrowserIdentifier = identifier
        }
        if let value = values["rules"] {
            guard let rows = value as? [[String: Any]] else { throw RouteError.invalid("rules must be an array of rule objects.") }
            for row in rows {
                guard Set(row.keys).isSubset(of: ["id", "domain", "includeSubdomains", "browserIdentifier", "profileDirectory"]),
                      let bool = row["includeSubdomains"] as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { throw RouteError.invalid("A rule contains unknown fields or an invalid includeSubdomains value.") }
            }
            config.rules = try JSONDecoder().decode([RouteRule].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        // Login-only changes remain possible when no browsers are installed or an
        // old selected browser was removed. Routing changes always validate fully.
        configuration = values["rules"] != nil || values["defaultBrowserIdentifier"] != nil ? try Routing.validate(config, browsers: browsers) : config
    }
}
final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("com.andrew.mactools.settingsChanged")
    private let defaults = UserDefaults.standard
    func configuration(browsers: [Browser]) -> Configuration {
        defaults.synchronize()
        if let data = defaults.data(forKey: "routingConfiguration"), let configuration = try? JSONDecoder().decode(Configuration.self, from: data) { return configuration }
        let defaultID = BrowserCatalog.systemDefault().flatMap { id in browsers.contains(where: { $0.identifier == id }) ? id : nil }
        return Configuration(defaultBrowserIdentifier: defaultID ?? browsers.first(where: { $0.identifier == "com.apple.Safari" })?.identifier ?? browsers.first?.identifier ?? "", rules: [])
    }
    func snapshot() -> SettingsSnapshot {
        let browsers = BrowserCatalog.browsers(), config = configuration(browsers: browsers), status = SMAppService.mainApp.status
        let name: String
        switch status { case .enabled: name = "enabled"; case .notRegistered: name = "notRegistered"; case .requiresApproval: name = "requiresApproval"; case .notFound: name = "notFound"; @unknown default: name = "unknown" }
        return SettingsSnapshot(launchAtLogin: status == .enabled, loginStatus: name, defaultBrowserIdentifier: config.defaultBrowserIdentifier, rules: config.rules, availableBrowsers: browsers, isDefaultBrowser: BrowserCatalog.isDefault)
    }
    func apply(data: Data) throws {
        let browsers = BrowserCatalog.browsers()
        let patch = try SettingsPatch(data: data, current: configuration(browsers: browsers), browsers: browsers)
        let encoded = try JSONEncoder().encode(patch.configuration)
        if let enabled = patch.launchAtLogin {
            if enabled && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
            if !enabled && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        }
        // One data value commits the complete routing configuration atomically.
        defaults.set(encoded, forKey: "routingConfiguration")
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: applicationIdentifier, userInfo: nil, deliverImmediately: true)
    }
    static func runCommand(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 2, ["read", "write"].contains(arguments[1]) else { throw RouteError.invalid("Usage: --mac-tools-settings read|write") }
            if arguments[1] == "write" { try shared.apply(data: FileHandle.standardInput.readDataToEndOfFile()) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var output = try encoder.encode(shared.snapshot()); output.append(10)
            FileHandle.standardOutput.write(output); return 0
        } catch {
            // Deliberately never echo supplied URLs or input JSON.
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1
        }
    }
}
