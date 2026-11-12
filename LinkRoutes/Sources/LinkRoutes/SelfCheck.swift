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
        return strips && untouched && unwraps && refusesScript && matches
    }
}
