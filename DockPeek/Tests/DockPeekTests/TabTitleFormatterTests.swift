import XCTest
@testable import DockPeek

final class TabTitleFormatterTests: XCTestCase {
    func testChromeStatusDoesNotObscurePageTitles() {
        XCTAssertEqual(TabTitleFormatter.displayTitle("Incidents · Dockpit - Memory usage - 247 MB", bundleIdentifier: "com.google.Chrome"), "Incidents · Dockpit")
        XCTAssertEqual(TabTitleFormatter.displayTitle("Tools · Dockpit - Part of group 🔎 Dockpit QA - Memory usage - 118 MB", bundleIdentifier: "com.google.Chrome"), "Tools · Dockpit")
        XCTAssertEqual(TabTitleFormatter.displayTitle("(3) Facebook - Memory usage - 1.2 GB", bundleIdentifier: "com.google.Chrome.beta"), "(3) Facebook")
    }

    func testUnrelatedTitlesAndAppsArePreserved() {
        let title = "Documentation - Memory usage - guide"
        XCTAssertEqual(TabTitleFormatter.displayTitle(title, bundleIdentifier: "com.google.Chrome"), title)
        let statusLikeTitle = "Report - Memory usage - 247 MB"
        XCTAssertEqual(TabTitleFormatter.displayTitle(statusLikeTitle, bundleIdentifier: "com.example.Editor"), statusLikeTitle)
        XCTAssertEqual(TabTitleFormatter.displayTitle(statusLikeTitle, bundleIdentifier: nil), statusLikeTitle)
    }
}
