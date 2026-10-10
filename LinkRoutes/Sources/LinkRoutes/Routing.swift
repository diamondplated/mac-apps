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
}
struct Configuration: Codable, Equatable {
    var defaultBrowserIdentifier: String
    var rules: [RouteRule]
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
        for index in normalized.rules.indices {
            normalized.rules[index].domain = try domain(normalized.rules[index].domain)
            let rule = normalized.rules[index]
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
    static func target(for url: URL, configuration: Configuration, browsers: [Browser]) -> RouteTarget? {
        let host = canonicalHost(url.host ?? "")
        for rule in configuration.rules {
            guard host == rule.domain || (rule.includeSubdomains && host.hasSuffix("." + rule.domain)) else { continue }
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
