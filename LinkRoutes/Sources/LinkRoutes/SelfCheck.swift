import Foundation

/// Pure checks behind `--self-check`. Nothing here touches preferences, the
/// network or the default browser.
enum SelfCheck {
    static func run() -> Bool {
        guard let url = try? Routing.webURL("https://example.com/path?q=1#anchor"), url.host == "example.com",
              (try? Routing.domain("EXAMPLE.COM")) == "example.com", !Routing.safeProfileDirectory("../Default") else { return false }
        let strips = LinkCleaning.stripTracking("https://example.com/a?utm_source=x&keep=%2F&fbclid=1#f") == "https://example.com/a?keep=%2F#f"
        let untouched = LinkCleaning.stripTracking("https://example.com/a?keep=1&b=2") == "https://example.com/a?keep=1&b=2"
        let wrapped = "https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Fx&sa=D"
        let unwraps = LinkCleaning.unwrap(wrapped) == "https://example.com/x"
        let refusesScript = LinkCleaning.unwrap("https://www.google.com/url?q=javascript%3Aalert(1)") == nil
        let rule = RouteRule(domain: "*", includeSubdomains: false, browserIdentifier: "com.apple.Safari", profileDirectory: nil, sourceBundleIdentifier: "com.tinyspeck.slackmacgap")
        let matches = Routing.matchesSource(rule, source: "com.tinyspeck.slackmacgap") && !Routing.matchesSource(rule, source: nil)
        return strips && untouched && unwraps && refusesScript && matches && files()
    }

    /// File rules, against a stand-in for Launch Services.
    private struct StandInDefaults: FileDefaultsService {
        func defaultApplication(forExtension ext: String) -> String? { "com.example.old" }
        func setDefaultApplication(_ bundleIdentifier: String, forExtension ext: String) throws {}
        func isInstalled(_ bundleIdentifier: String) -> Bool { bundleIdentifier != applicationIdentifier }
        func candidateApplications(forExtension ext: String) -> [String] { [] }
    }
    private static func files() -> Bool {
        let service = StandInDefaults()
        let rules = [FileRule(id: "1", fileExtension: "md", folder: "/Users/someone/Work", applicationIdentifier: "com.example.editor")]
        let inside = FileRouting.decide(file: URL(fileURLWithPath: "/Users/someone/Work/../Work/notes.md"), rules: rules, fallbacks: ["md": TakenType(fallback: "com.example.old")], service: service, home: "/Users/someone")
        let outside = FileRouting.decide(file: URL(fileURLWithPath: "/Users/someone/Other/notes.md"), rules: rules, fallbacks: ["md": TakenType(fallback: "com.example.old")], service: service, home: "/Users/someone")
        let blocked = (try? FileRouting.normalizedExtension("sh")) == nil && (try? FileRouting.normalizedExtension("MD")) == "md"
        return inside == .open(application: "com.example.editor", usedFallback: false) && outside == .open(application: "com.example.old", usedFallback: true) && blocked
    }
}
