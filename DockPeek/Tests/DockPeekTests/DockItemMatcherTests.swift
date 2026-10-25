import XCTest
@testable import DockPeek

final class DockItemMatcherTests: XCTestCase {
    private let code = DockItemMatcher.Candidate(name: "Code", bundleURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
    private let safari = DockItemMatcher.Candidate(name: "Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"))

    func testNonRunningAppWhoseNameContainsAnotherAppsNameMatchesNothing() {
        XCTAssertNil(DockItemMatcher.index(title: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"), in: [code, safari]))
        XCTAssertNil(DockItemMatcher.index(title: "Xcode", url: nil, in: [code, safari]))
        XCTAssertNil(DockItemMatcher.index(title: "Saf", url: nil, in: [code, safari]))
    }

    func testBundleURLWinsThenExactNameIgnoringCase() {
        XCTAssertEqual(DockItemMatcher.index(title: "Visual Studio Code", url: code.bundleURL, in: [safari, code]), 1)
        XCTAssertEqual(DockItemMatcher.index(title: "safari", url: nil, in: [code, safari]), 1)
        XCTAssertNil(DockItemMatcher.index(title: "", url: nil, in: [code, safari]))
    }
}
