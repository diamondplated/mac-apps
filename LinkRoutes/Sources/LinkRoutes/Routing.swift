import Foundation
import CoreFoundation
import Darwin

let applicationIdentifier = "com.andrew.linkroutes"

struct BrowserProfile: Codable, Equatable, Identifiable {
    let directory: String
    let name: String
    var id: String { directory }
}
struct Browser: Codable, Equatable, Identifiable {
    let identifier: String
    let name: String
    let profiles: [BrowserProfile]
    var id: String { identifier }
}
struct RouteRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var domain: String
    var includeSubdomains: Bool
    var browserIdentifier: String
    var profileDirectory: String?
    /// Bundle identifier of the app the link was clicked in. `nil` matches any app.
    var sourceBundleIdentifier: String?
}
struct Configuration: Codable, Equatable {
    var defaultBrowserIdentifier: String
    var rules: [RouteRule]
    var stripsTrackingParameters: Bool
    var unwrapsRedirects: Bool
    init(defaultBrowserIdentifier: String, rules: [RouteRule], stripsTrackingParameters: Bool = true, unwrapsRedirects: Bool = false) {
        self.defaultBrowserIdentifier = defaultBrowserIdentifier
        self.rules = rules
        self.stripsTrackingParameters = stripsTrackingParameters
        self.unwrapsRedirects = unwrapsRedirects
    }
    // Configurations saved by earlier versions have no cleaning keys.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultBrowserIdentifier = try values.decode(String.self, forKey: .defaultBrowserIdentifier)
        rules = try values.decode([RouteRule].self, forKey: .rules)
        stripsTrackingParameters = try values.decodeIfPresent(Bool.self, forKey: .stripsTrackingParameters) ?? true
        unwrapsRedirects = try values.decodeIfPresent(Bool.self, forKey: .unwrapsRedirects) ?? false
    }
}
struct RouteTarget: Equatable {
    let browserIdentifier: String
    let profileDirectory: String?
    let matchedDomain: String?
}
enum RouteError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
enum Routing {
    static func domain(_ text: String) throws -> String {
        let result = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 253, !result.hasPrefix("."), !result.hasSuffix("."),
              result.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }),
              result.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            throw RouteError.invalid("Enter a hostname such as example.com, without a scheme, path, or wildcard. Use punycode for international domains.")
        }
        return result
    }
    /// The website condition that matches every site; valid only with a source app.
    static let anyWebsite = "*"
    static func sourceBundleIdentifier(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.count <= 255,
              text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_") }) else {
            throw RouteError.invalid("A rule has an invalid source app.")
        }
        return text
    }
    static func webURL(_ text: String) throws -> URL {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw RouteError.invalid("Enter an HTTP or HTTPS link without credentials or whitespace.") }
        // URLComponents may encode raw control characters, but encoded control characters
        // are also disallowed to avoid ambiguous browser command interpretation.
        guard let decoded = text.removingPercentEncoding, !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RouteError.invalid("Links cannot contain control characters or invalid percent escapes.")
        }
        let canonical = canonicalHost(host)
        if canonical.contains(":") {
            let literal = canonical.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var address = in6_addr()
            guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw RouteError.invalid("The link contains an invalid host.") }
        } else {
            _ = try domain(canonical)
        }
        return url
    }
    static func canonicalHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }
    static func validate(_ configuration: Configuration, browsers: [Browser]) throws -> Configuration {
        let browserMap = Dictionary(uniqueKeysWithValues: browsers.map { ($0.identifier, $0) })
        guard configuration.defaultBrowserIdentifier != applicationIdentifier, browserMap[configuration.defaultBrowserIdentifier] != nil else {
            throw RouteError.invalid("Choose an installed browser as the fallback.")
        }
        guard configuration.rules.count <= 200, Set(configuration.rules.map(\.id)).count == configuration.rules.count else {
            throw RouteError.invalid("Rules must have unique identifiers, with at most 200 rules.")
        }
        var normalized = configuration
        var seen = Set<String>()
        for index in normalized.rules.indices {
            if let source = normalized.rules[index].sourceBundleIdentifier { normalized.rules[index].sourceBundleIdentifier = try sourceBundleIdentifier(source) }
            if normalized.rules[index].domain.trimmingCharacters(in: .whitespacesAndNewlines) == anyWebsite {
                guard normalized.rules[index].sourceBundleIdentifier != nil else {
                    throw RouteError.invalid("A rule for every website needs a source app.")
                }
                normalized.rules[index].domain = anyWebsite
            } else {
                normalized.rules[index].domain = try domain(normalized.rules[index].domain)
            }
            let rule = normalized.rules[index]
            let scope = rule.domain == anyWebsite ? "any" : (rule.includeSubdomains ? "sub" : "exact")
            let key = [rule.domain, scope, rule.sourceBundleIdentifier?.lowercased() ?? ""].joined(separator: "|")
            guard seen.insert(key).inserted else { throw RouteError.invalid("Two rules have the same website and source app.") }
            guard rule.browserIdentifier != applicationIdentifier, let browser = browserMap[rule.browserIdentifier] else {
                throw RouteError.invalid("A rule refers to a browser that is not installed.")
            }
            if let directory = rule.profileDirectory {
                guard safeProfileDirectory(directory), browser.profiles.contains(where: { $0.directory == directory }) else {
                    throw RouteError.invalid("A rule refers to an unavailable browser profile.")
                }
            }
        }
        return normalized
    }
    /// A rule's website condition. `*` matches every site.
    static func matchesWebsite(_ rule: RouteRule, host: String) -> Bool {
        rule.domain == anyWebsite || host == rule.domain || (rule.includeSubdomains && host.hasSuffix("." + rule.domain))
    }
    /// A rule without a source matches any app. A rule with one needs a known,
    /// equal source; an unknown source never matches it.
    static func matchesSource(_ rule: RouteRule, source: String?) -> Bool {
        guard let wanted = rule.sourceBundleIdentifier else { return true }
        guard let source else { return false }
        return wanted.caseInsensitiveCompare(source) == .orderedSame
    }
    static func target(for url: URL, source: String? = nil, configuration: Configuration, browsers: [Browser]) -> RouteTarget? {
        let host = canonicalHost(url.host ?? "")
        for rule in configuration.rules {
            guard matchesWebsite(rule, host: host), matchesSource(rule, source: source) else { continue }
            if rule.profileDirectory != nil && !browsers.contains(where: { $0.identifier == rule.browserIdentifier && $0.identifier != applicationIdentifier }) { return nil }
            if let browser = browsers.first(where: { $0.identifier == rule.browserIdentifier && $0.identifier != applicationIdentifier }) {
                // A missing profile must not silently send a work link into a different account.
                if let profile = rule.profileDirectory, !browser.profiles.contains(where: { $0.directory == profile }) { return nil }
                return RouteTarget(browserIdentifier: browser.identifier, profileDirectory: rule.profileDirectory, matchedDomain: rule.domain)
            }
        }
        guard let browser = browsers.first(where: { $0.identifier == configuration.defaultBrowserIdentifier && $0.identifier != applicationIdentifier }) else { return nil }
        return RouteTarget(browserIdentifier: browser.identifier, profileDirectory: nil, matchedDomain: nil)
    }
    static func safeProfileDirectory(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && value.utf8.count <= 255 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func profiles(data: Data, root: URL, existingDirectories: (URL) -> Bool = { url in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }) -> [BrowserProfile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return cache.compactMap { directory, value in
            guard safeProfileDirectory(directory), let details = value as? [String: Any], let name = details["name"] as? String,
                  !name.isEmpty, name.count < 200 else { return nil }
            let path = root.appendingPathComponent(directory, isDirectory: true)
            guard path.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot), existingDirectories(path) else { return nil }
            return BrowserProfile(directory: directory, name: name)
        }.sorted { $0.directory < $1.directory }
    }
}
