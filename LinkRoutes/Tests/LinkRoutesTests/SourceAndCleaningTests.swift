import XCTest
@testable import LinkRoutes

final class SourceRuleTests: XCTestCase {
    let safari = Browser(identifier: "com.apple.Safari", name: "Safari", profiles: [])
    let chrome = Browser(identifier: "com.google.Chrome", name: "Chrome", profiles: [BrowserProfile(directory: "Profile 1", name: "Work")])
    var browsers: [Browser] { [safari, chrome] }
    let slack = "com.tinyspeck.slackmacgap"
    let messages = "com.apple.MobileSMS"
    func config(_ rules: [RouteRule]) -> Configuration { Configuration(defaultBrowserIdentifier: safari.identifier, rules: rules) }
    func rule(_ domain: String = "*", source: String? = nil, subdomains: Bool = true, browser: Browser? = nil, profile: String? = nil) -> RouteRule {
        RouteRule(domain: domain, includeSubdomains: subdomains, browserIdentifier: (browser ?? chrome).identifier, profileDirectory: profile, sourceBundleIdentifier: source)
    }
    func browserFor(_ link: String, source: String?, _ rules: [RouteRule]) throws -> String? {
        Routing.target(for: try Routing.webURL(link), source: source, configuration: config(rules), browsers: browsers)?.browserIdentifier
    }

    func testKnownSourceMatchesAndOtherSourcesDoNot() throws {
        let rules = [rule(source: slack, profile: "Profile 1")]
        XCTAssertEqual(try browserFor("https://example.com", source: slack, rules), chrome.identifier)
        XCTAssertEqual(try browserFor("https://example.com", source: messages, rules), safari.identifier)
    }
    func testUnknownSourceOnlyMatchesRulesWithoutASource() throws {
        XCTAssertEqual(try browserFor("https://example.com", source: nil, [rule(source: slack)]), safari.identifier)
        XCTAssertEqual(try browserFor("https://example.com", source: nil, [rule("example.com")]), chrome.identifier)
        XCTAssertEqual(try browserFor("https://example.com", source: nil, [rule(source: slack), rule("example.com")]), chrome.identifier)
    }
    func testSourceMatchIgnoresCase() throws {
        XCTAssertEqual(try browserFor("https://example.com", source: slack.uppercased(), [rule(source: slack)]), chrome.identifier)
    }
    func testStarMatchesEverySiteForItsSourceOnly() throws {
        let rules = [rule("*", source: slack)]
        for link in ["https://example.com", "https://a.b.example.org/x", "https://[::1]/"] {
            XCTAssertEqual(try browserFor(link, source: slack, rules), chrome.identifier, link)
            XCTAssertEqual(try browserFor(link, source: messages, rules), safari.identifier, link)
        }
    }
    func testWebsiteAndSourceCombine() throws {
        let rules = [rule("example.com", source: slack)]
        XCTAssertEqual(try browserFor("https://example.com", source: slack, rules), chrome.identifier)
        XCTAssertEqual(try browserFor("https://example.com", source: messages, rules), safari.identifier)
        XCTAssertEqual(try browserFor("https://other.org", source: slack, rules), safari.identifier)
    }
    func testOrderStillDecides() throws {
        let specific = rule("example.com", source: slack, browser: safari)
        let broad = rule("*", source: slack, browser: chrome)
        XCTAssertEqual(try browserFor("https://example.com", source: slack, [specific, broad]), safari.identifier)
        XCTAssertEqual(try browserFor("https://example.com", source: slack, [broad, specific]), chrome.identifier)
    }
    func testRuleWithoutSourceBehavesAsBefore() throws {
        XCTAssertEqual(try browserFor("https://work.example.com", source: slack, [rule("example.com")]), chrome.identifier)
        XCTAssertEqual(try browserFor("https://work.example.com", source: nil, [rule("example.com")]), chrome.identifier)
    }

    func testValidationOfStarAndSource() throws {
        XCTAssertThrowsError(try Routing.validate(config([rule("*")]), browsers: browsers))
        XCTAssertEqual(try Routing.validate(config([rule("*", source: slack)]), browsers: browsers).rules.first?.domain, "*")
        for bad in ["", " ", "has space", "a/b", String(repeating: "a", count: 256), "é.app"] {
            XCTAssertThrowsError(try Routing.validate(config([rule("example.com", source: bad)]), browsers: browsers), bad)
        }
        XCTAssertNoThrow(try Routing.validate(config([rule("example.com", source: "com.foo-bar_baz.App")]), browsers: browsers))
        XCTAssertNoThrow(try Routing.validate(config([rule("example.com", source: String(repeating: "a", count: 255))]), browsers: browsers))
    }
    func testDuplicatesNeedWebsiteSubdomainAndSourceToAllMatch() throws {
        func valid(_ rules: [RouteRule]) -> Bool { (try? Routing.validate(config(rules), browsers: browsers)) != nil }
        XCTAssertFalse(valid([rule("example.com", source: slack), rule("example.com", source: slack)]))
        XCTAssertFalse(valid([rule("example.com", source: slack), rule("example.com", source: slack.uppercased())]))
        XCTAssertFalse(valid([rule("*", source: slack), rule("*", source: slack)]))
        XCTAssertFalse(valid([rule("example.com"), rule("EXAMPLE.com")]))
        XCTAssertTrue(valid([rule("example.com", source: slack), rule("example.com", source: messages)]))
        XCTAssertTrue(valid([rule("example.com", source: slack), rule("example.com")]))
        XCTAssertTrue(valid([rule("example.com", subdomains: true), rule("example.com", subdomains: false)]))
        XCTAssertTrue(valid([rule("*", source: slack), rule("example.com", source: slack)]))
    }
    func testLoopAndProfileSafeguardsStillApplyToSourceRules() {
        let loop = RouteRule(domain: "*", includeSubdomains: false, browserIdentifier: applicationIdentifier, profileDirectory: nil, sourceBundleIdentifier: slack)
        XCTAssertThrowsError(try Routing.validate(config([loop]), browsers: browsers))
        XCTAssertThrowsError(try Routing.validate(config([rule("*", source: slack, profile: "../Profile 1")]), browsers: browsers))
        XCTAssertThrowsError(try Routing.validate(config([rule("*", source: slack, profile: "Missing")]), browsers: browsers))
        let many = (0..<201).map { rule("d\($0).com", source: slack) }
        XCTAssertThrowsError(try Routing.validate(config(many), browsers: browsers))
    }
    func testMissingProfileForSourceRuleStillFailsClosed() throws {
        XCTAssertNil(try browserFor("https://example.com", source: slack, [rule(source: slack, profile: "Missing")]))
    }

    func patch(_ json: String) throws -> SettingsPatch {
        try SettingsPatch(data: Data(json.utf8), current: config([]), browsers: browsers)
    }
    func testPatchAcceptsSourceFieldsAndRoundTrips() throws {
        let rules = "{\"rules\":[{\"id\":\"\(UUID().uuidString)\",\"domain\":\"*\",\"includeSubdomains\":false,\"browserIdentifier\":\"com.google.Chrome\",\"profileDirectory\":\"Profile 1\",\"sourceBundleIdentifier\":\"\(slack)\"}]}"
        let result = try patch(rules).configuration
        XCTAssertEqual(result.rules.first?.sourceBundleIdentifier, slack)
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        let withNull = "{\"rules\":[{\"id\":\"\(UUID().uuidString)\",\"domain\":\"example.com\",\"includeSubdomains\":true,\"browserIdentifier\":\"com.google.Chrome\",\"sourceBundleIdentifier\":null}]}"
        XCTAssertNil(try patch(withNull).configuration.rules.first?.sourceBundleIdentifier)
    }
    func testPatchRejectsBadSourceFields() {
        let id = UUID().uuidString
        func row(_ domain: String, _ source: String) -> String { "{\"rules\":[{\"id\":\"\(id)\",\"domain\":\"\(domain)\",\"includeSubdomains\":true,\"browserIdentifier\":\"com.google.Chrome\",\"sourceBundleIdentifier\":\(source)}]}" }
        XCTAssertThrowsError(try patch(row("*", "null")))
        XCTAssertThrowsError(try patch(row("example.com", "5")))
        XCTAssertThrowsError(try patch(row("example.com", "\"bad id\"")))
        XCTAssertThrowsError(try patch(row("example.com", "\"\"")))
        XCTAssertThrowsError(try patch("{\"rules\":[{\"id\":\"\(id)\",\"domain\":\"*\",\"includeSubdomains\":true,\"browserIdentifier\":\"com.google.Chrome\"}]}"))
    }
    func testCleaningSettingsAreBooleansWithDefaultsAndOldDataLoads() throws {
        let defaults = config([])
        XCTAssertTrue(defaults.stripsTrackingParameters)
        XCTAssertFalse(defaults.unwrapsRedirects)
        XCTAssertTrue(try patch("{}").configuration.stripsTrackingParameters)
        let changed = try patch("{\"stripsTrackingParameters\":false,\"unwrapsRedirects\":true}").configuration
        XCTAssertFalse(changed.stripsTrackingParameters)
        XCTAssertTrue(changed.unwrapsRedirects)
        for json in ["{\"stripsTrackingParameters\":1}", "{\"unwrapsRedirects\":\"yes\"}", "{\"unwrapsRedirects\":null}"] { XCTAssertThrowsError(try patch(json), json) }
        let old = Data("{\"defaultBrowserIdentifier\":\"com.apple.Safari\",\"rules\":[{\"id\":\"\(UUID().uuidString)\",\"domain\":\"example.com\",\"includeSubdomains\":true,\"browserIdentifier\":\"com.google.Chrome\"}]}".utf8)
        let loaded = try JSONDecoder().decode(Configuration.self, from: old)
        XCTAssertEqual(loaded.rules.count, 1)
        XCTAssertNil(loaded.rules[0].sourceBundleIdentifier)
        XCTAssertTrue(loaded.stripsTrackingParameters)
        XCTAssertFalse(loaded.unwrapsRedirects)
    }
    func testSourceLookup() {
        XCTAssertNil(LinkSource.bundleIdentifier(processIdentifier: nil) { _ in "x" })
        XCTAssertNil(LinkSource.bundleIdentifier(processIdentifier: 0) { _ in "x" })
        XCTAssertNil(LinkSource.bundleIdentifier(processIdentifier: 42) { _ in nil })
        XCTAssertEqual(LinkSource.bundleIdentifier(processIdentifier: 42) { $0 == 42 ? "com.foo" : nil }, "com.foo")
    }
}

final class LinkCleaningTests: XCTestCase {
    func testStripTable() {
        let cases: [(String, String)] = [
            ("https://e.com/a?utm_source=x&utm_medium=y&utm_campaign=z&utm_content=c&utm_term=t&utm_anything=1", "https://e.com/a"),
            ("https://e.com/?fbclid=1", "https://e.com/"),
            ("https://e.com/?gclid=1&gclsrc=2&dclid=3&gbraid=4&wbraid=5", "https://e.com/"),
            ("https://e.com/?msclkid=1&mc_cid=2&mc_eid=3&igshid=4&yclid=5&twclid=6&ttclid=7", "https://e.com/"),
            ("https://e.com/?_hsenc=1&_hsmi=2&vero_id=3&oly_enc_id=4&oly_anon_id=5", "https://e.com/"),
            ("https://e.com/?UTM_Source=x&FBCLID=1", "https://e.com/"),
            ("https://e.com/?utm%5Fsource=x&keep=1", "https://e.com/?keep=1"),
            ("https://e.com/a?id=7&utm_source=x&q=a%20b%2Fc&gclid=9&z=%E2%9C%93", "https://e.com/a?id=7&q=a%20b%2Fc&z=%E2%9C%93"),
            ("https://e.com/a?utm_source=x&id=7#sec?utm_medium=1", "https://e.com/a?id=7#sec?utm_medium=1"),
            ("https://e.com/a?fbclid=1#frag", "https://e.com/a#frag"),
            ("https://e.com/a?utm_source=1&utm_source=2&k=1&utm_source=3", "https://e.com/a?k=1"),
            ("https://e.com/a?k=1&k=2&fbclid", "https://e.com/a?k=1&k=2"),
            ("https://e.com/a?a=1&&b=2&fbclid=1", "https://e.com/a?a=1&&b=2"),
        ]
        for (input, expected) in cases { XCTAssertEqual(LinkCleaning.stripTracking(input), expected, input) }
    }
    func testNothingToStripIsByteForByte() {
        for link in ["https://e.com", "https://e.com/", "https://e.com/?", "https://e.com/a?", "https://e.com/a?x=1&y=%2F#f", "https://e.com/a#utm_source=1",
                     "https://e.com/?utmx=1&my_utm_source=2&gclid2=3&fbclidx=4&xfbclid=5", "https://e.com/?q=utm_source%3D1", "https://e.com/?a=1&&b"] {
            XCTAssertEqual(LinkCleaning.stripTracking(link), link)
        }
    }
    func testUnwrapTable() {
        let dest = "https://example.com/page?a=1&b=2"
        let enc = "https%3A%2F%2Fexample.com%2Fpage%3Fa%3D1%26b%3D2"
        let cases: [(String, String?)] = [
            ("https://nam02.safelinks.protection.outlook.com/?url=\(enc)&data=05%7C01&reserved=0", dest),
            ("https://eur.safelinks.protection.outlook.com/?data=1&url=\(enc)", dest),
            ("https://www.google.com/url?q=\(enc)&sa=D&source=x", dest),
            ("https://www.google.com/url?sa=t&url=\(enc)", dest),
            ("https://l.facebook.com/l.php?u=\(enc)&h=AT0", dest),
            ("https://lm.facebook.com/l.php?u=\(enc)", dest),
            ("https://slack-redir.net/link?url=\(enc)", dest),
            ("https://www.google.com/search?q=\(enc)", nil),
            ("https://www.google.com/url?q=\(enc)".replacingOccurrences(of: "www.google.com", with: "google.com"), nil),
            ("https://notsafelinks.protection.outlook.com/?url=\(enc)", nil),
            ("https://safelinks.protection.outlook.com.evil.com/?url=\(enc)", nil),
            ("https://l.facebook.com/l.php?url=\(enc)", nil),
            ("https://example.com/?url=\(enc)", nil),
            ("https://slack-redir.net/link", nil),
            ("https://www.google.com/url?q=javascript%3Aalert(1)", nil),
            ("https://www.google.com/url?q=file%3A%2F%2F%2Ftmp%2Fx", nil),
            ("https://www.google.com/url?q=ftp%3A%2F%2Fexample.com", nil),
            ("https://www.google.com/url?q=https%3A%2F%2F", nil),
            ("https://www.google.com/url?q=not%20a%20link", nil),
            ("https://www.google.com/url?q=https%3A%2F%2Fuser%3Apw%40example.com%2F", nil),
            ("https://www.google.com/url?q=https%3A%2F%2Fexample.com%2F%250a", nil),
            ("https://www.google.com/url?q=", nil),
        ]
        for (input, expected) in cases { XCTAssertEqual(LinkCleaning.unwrap(input), expected, input) }
    }
    func testGoogleFallsBackToUrlWhenQIsNotALink() {
        XCTAssertEqual(LinkCleaning.unwrap("https://www.google.com/url?q=hello&url=https%3A%2F%2Fexample.com%2F"), "https://example.com/")
    }
    func testNestedWrappersAndThreeLayerLimit() {
        func wrap(_ inner: String) -> String { "https://slack-redir.net/link?url=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        let real = "https://example.com/final"
        let one = wrap(real), two = wrap(one), three = wrap(two), four = wrap(three)
        XCTAssertEqual(LinkCleaning.unwrapAll(one), real)
        XCTAssertEqual(LinkCleaning.unwrapAll(two), real)
        XCTAssertEqual(LinkCleaning.unwrapAll(three), real)
        XCTAssertEqual(LinkCleaning.unwrapAll(four), one, "a fourth layer is left wrapped")
        XCTAssertEqual(LinkCleaning.unwrapAll(real), real)
        let mixed = "https://www.google.com/url?q=" + wrap(real).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(LinkCleaning.unwrapAll(mixed), real)
    }
    func testCleanPipeline() throws {
        let wrapped = try Routing.webURL("https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fp%3Futm_source%3Dx%26k%3D1&data=1")
        XCTAssertEqual(LinkCleaning.clean(wrapped, stripsTracking: true, unwrapsRedirects: true).absoluteString, "https://example.com/p?k=1")
        XCTAssertEqual(LinkCleaning.clean(wrapped, stripsTracking: false, unwrapsRedirects: true).absoluteString, "https://example.com/p?utm_source=x&k=1")
        XCTAssertEqual(LinkCleaning.clean(wrapped, stripsTracking: true, unwrapsRedirects: false), wrapped)
        XCTAssertEqual(LinkCleaning.clean(wrapped, stripsTracking: false, unwrapsRedirects: false), wrapped)
        let plain = try Routing.webURL("https://example.com/a?fbclid=1&k=%2F#x")
        XCTAssertEqual(LinkCleaning.clean(plain, stripsTracking: true, unwrapsRedirects: false).absoluteString, "https://example.com/a?k=%2F#x")
        XCTAssertEqual(LinkCleaning.clean(plain, stripsTracking: false, unwrapsRedirects: true), plain)
    }
    func testRulesSeeTheUnwrappedSite() throws {
        let chrome = Browser(identifier: "com.google.Chrome", name: "Chrome", profiles: [])
        let safari = Browser(identifier: "com.apple.Safari", name: "Safari", profiles: [])
        let config = Configuration(defaultBrowserIdentifier: safari.identifier, rules: [RouteRule(domain: "example.com", includeSubdomains: true, browserIdentifier: chrome.identifier, profileDirectory: nil)])
        let wrapped = try Routing.webURL("https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2F")
        XCTAssertEqual(Routing.target(for: wrapped, configuration: config, browsers: [safari, chrome])?.browserIdentifier, safari.identifier)
        let cleaned = LinkCleaning.clean(wrapped, stripsTracking: true, unwrapsRedirects: true)
        XCTAssertEqual(Routing.target(for: cleaned, configuration: config, browsers: [safari, chrome])?.browserIdentifier, chrome.identifier)
    }
    func testSelfCheckPasses() { XCTAssertTrue(SelfCheck.run()) }
}
