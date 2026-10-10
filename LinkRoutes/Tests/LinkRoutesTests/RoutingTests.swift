import XCTest
@testable import LinkRoutes
final class RoutingTests: XCTestCase {
    let safari = Browser(identifier: "com.apple.Safari", name: "Safari", profiles: [])
    let chrome = Browser(identifier: "com.google.Chrome", name: "Chrome", profiles: [BrowserProfile(directory: "Profile 1", name: "Work")])
    var browsers: [Browser] { [safari, chrome] }
    func config(_ rules: [RouteRule] = []) -> Configuration { Configuration(defaultBrowserIdentifier: safari.identifier, rules: rules) }
    func rule(_ domain: String = "example.com", subdomains: Bool = true, profile: String? = nil) -> RouteRule { RouteRule(domain: domain, includeSubdomains: subdomains, browserIdentifier: chrome.identifier, profileDirectory: profile) }
    func testDomainBoundaryAndPreservedURL() throws {
        let configuration = try Routing.validate(config([rule()]), browsers: browsers)
        for host in ["example.com", "work.example.com"] {
            let url = try Routing.webURL("https://\(host)/a%20b?x=1&y=%2F#fragment")
            XCTAssertEqual(Routing.target(for: url, configuration: configuration, browsers: browsers)?.browserIdentifier, chrome.identifier)
            XCTAssertEqual(url.absoluteString, "https://\(host)/a%20b?x=1&y=%2F#fragment")
        }
        for host in ["evil-example.com", "example.com.evil.com"] {
            XCTAssertEqual(Routing.target(for: try Routing.webURL("https://\(host)"), configuration: configuration, browsers: browsers)?.browserIdentifier, safari.identifier)
        }
    }
    func testExactDomainAndFirstMatchingRule() throws {
        let first = rule(subdomains: false, profile: "Profile 1")
        let config = config([first, rule()])
        XCTAssertEqual(Routing.target(for: try Routing.webURL("https://example.com"), configuration: config, browsers: browsers)?.profileDirectory, "Profile 1")
        XCTAssertNil(Routing.target(for: try Routing.webURL("https://work.example.com"), configuration: config, browsers: browsers)?.profileDirectory)
    }
    func testIPv6AndTrailingDotHostsPreserveLinks() throws {
        let ipv6 = try Routing.webURL("https://[::1]:8443/a?q=1#test")
        XCTAssertEqual(ipv6.absoluteString, "https://[::1]:8443/a?q=1#test")
        XCTAssertEqual(Routing.target(for: ipv6, configuration: config([rule()]), browsers: browsers)?.browserIdentifier, safari.identifier)
        let trailing = try Routing.webURL("https://example.com./path")
        XCTAssertEqual(trailing.absoluteString, "https://example.com./path")
        XCTAssertEqual(Routing.target(for: trailing, configuration: config([rule()]), browsers: browsers)?.browserIdentifier, chrome.identifier)
    }
    func testUnsafeURLsRejected() {
        for link in ["file:///tmp/foo", "javascript:alert(1)", "https://user:secret@example.com", "https://user@example.com", "https://example.com/\n", "https://example.com/%0a", "https://example.com/%00", "https://example.com/%xx", "https://example.com:99999", "https://", "https://example.com/a b"] {
            XCTAssertThrowsError(try Routing.webURL(link), link)
        }
    }
    func testDomainsNormalizeAndValidate() throws {
        XCTAssertEqual(try Routing.domain(" EXAMPLE.COM "), "example.com")
        for domain in ["https://example.com", "*.example.com", "example.com/path", "-bad.com", "example..com", "example.com."] { XCTAssertThrowsError(try Routing.domain(domain)) }
    }
    func testUnavailableRuleFallsBackAndMissingFallbackFailsClosed() throws {
        let url = try Routing.webURL("https://example.com")
        XCTAssertEqual(Routing.target(for: url, configuration: config([rule()]), browsers: [safari])?.browserIdentifier, safari.identifier)
        XCTAssertNil(Routing.target(for: url, configuration: config([rule(profile: "Missing")]), browsers: browsers))
        XCTAssertNil(Routing.target(for: url, configuration: config([rule(profile: "Profile 1")]), browsers: [safari]))
        XCTAssertNil(Routing.target(for: url, configuration: Configuration(defaultBrowserIdentifier: applicationIdentifier, rules: []), browsers: browsers))
        XCTAssertNil(Routing.target(for: url, configuration: config(), browsers: [chrome]))
    }
    func testRulesRejectLoopsDuplicatesAndUnavailableProfiles() {
        XCTAssertThrowsError(try Routing.validate(Configuration(defaultBrowserIdentifier: applicationIdentifier, rules: []), browsers: browsers))
        let duplicate = rule()
        XCTAssertThrowsError(try Routing.validate(config([duplicate, duplicate]), browsers: browsers))
        XCTAssertThrowsError(try Routing.validate(config([rule(profile: "../Profile 1")]), browsers: browsers))
        XCTAssertThrowsError(try Routing.validate(config([rule(profile: "Missing")]), browsers: browsers))
    }
    func testPatchValidationBeforeMutationAndUnknownFields() throws {
        for json in ["{\"launchAtLogin\":1}", "{\"isDefaultBrowser\":true}", "{\"launchAtLogin\":true,\"defaultBrowserIdentifier\":\"com.andrew.linkroutes\"}", "{\"rules\":[{\"id\":\"no\",\"includeSubdomains\":true}]}"] {
            XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8), current: config(), browsers: browsers))
        }
        let patch = try SettingsPatch(data: Data("{\"launchAtLogin\":false}".utf8), current: Configuration(defaultBrowserIdentifier: "", rules: []), browsers: [])
        XCTAssertEqual(patch.launchAtLogin, false)
    }
    func testProfilesRejectTraversalMissingAndSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: outside)
        let data = Data("{\"profile\":{\"info_cache\":{\"Default\":{\"name\":\"Personal\"},\"../evil\":{\"name\":\"Bad\"},\"Missing\":{\"name\":\"Missing\"},\"Escape\":{\"name\":\"Escape\"}}}}".utf8)
        XCTAssertEqual(Routing.profiles(data: data, root: root), [BrowserProfile(directory: "Default", name: "Personal")])
    }
}
