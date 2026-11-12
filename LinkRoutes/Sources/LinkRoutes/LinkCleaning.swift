import Foundation

/// Tidies a link before it is routed. Everything here is a pure function of the
/// link text: no network request, no redirect following, nothing logged or stored.
enum LinkCleaning {
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid",
        "yclid", "twclid", "ttclid", "_hsenc", "_hsmi", "vero_id", "oly_enc_id", "oly_anon_id"
    ]
    static let maximumUnwrapDepth = 3

    static func isTracking(name: String) -> Bool {
        let lower = (name.removingPercentEncoding ?? name).lowercased()
        return lower.hasPrefix("utm_") || trackingParameters.contains(lower)
    }

    /// Removes tracking parameters from the query. Kept parameters, the fragment
    /// and the rest of the link stay byte-identical; with nothing to remove the
    /// input is returned unchanged.
    static func stripTracking(_ link: String) -> String {
        let hash = link.firstIndex(of: "#")
        let beforeFragment = hash.map { link[..<$0] } ?? Substring(link)
        let fragment = hash.map { link[$0...] } ?? ""
        guard let question = beforeFragment.firstIndex(of: "?") else { return link }
        let base = beforeFragment[..<question]
        let query = beforeFragment[beforeFragment.index(after: question)...]
        let parts = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = parts.filter { part in
            let name = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return !isTracking(name: String(name))
        }
        guard kept.count != parts.count else { return link }
        return kept.isEmpty ? String(base) + fragment : String(base) + "?" + kept.joined(separator: "&") + fragment
    }

    /// The destination written inside a known redirect wrapper, when it is a
    /// valid http(s) link. `nil` when the link is not a wrapper or the
    /// destination is unusable.
    static func unwrap(_ link: String) -> String? {
        guard let components = URLComponents(string: link), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased() else { return nil }
        let names: [String]
        switch (host, components.path) {
        case (_, _) where host.hasSuffix(".safelinks.protection.outlook.com"): names = ["url"]
        case ("www.google.com", "/url"): names = ["q", "url"]
        case ("l.facebook.com", "/l.php"), ("lm.facebook.com", "/l.php"): names = ["u"]
        case ("slack-redir.net", "/link"): names = ["url"]
        default: return nil
        }
        for name in names {
            guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
                  let destination = try? Routing.webURL(value) else { continue }
            return destination.absoluteString
        }
        return nil
    }

    static func unwrapAll(_ link: String) -> String {
        var current = link
        for _ in 0..<maximumUnwrapDepth {
            guard let next = unwrap(current) else { break }
            current = next
        }
        return current
    }

    /// The link to route: unwrapped first, so tracking parameters inside the
    /// destination are stripped too and rules see the real site.
    static func clean(_ url: URL, stripsTracking: Bool, unwrapsRedirects: Bool) -> URL {
        var link = url.absoluteString
        if unwrapsRedirects { link = unwrapAll(link) }
        if stripsTracking { link = stripTracking(link) }
        guard link != url.absoluteString else { return url }
        return (try? Routing.webURL(link)) ?? url
    }
}

/// Finds which app a link was clicked in, from the Apple Event that delivered it.
enum LinkSource {
    /// `nil` when there is no sender, the process has quit, or it has no bundle identifier.
    static func bundleIdentifier(processIdentifier: Int32?, resolver: (Int32) -> String?) -> String? {
        guard let processIdentifier, processIdentifier > 0 else { return nil }
        return resolver(processIdentifier)
    }
}
