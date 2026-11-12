import XCTest
@testable import MacToolsCore

final class ManagedAppTests: XCTestCase {
    // Bundle identifiers key macOS permission grants and preferences; changing one strands both.
    func testBundleIdentitiesArePinned() {
        let expected: [ManagedApp: String] = [
            .dockPeek: "com.andrew.dockpeek",
            .screenWren: "io.github.diamondplated.ScreenWren",
            .scrollSplit: "com.andrew.scrollsplit",
            .linkRoutes: "com.andrew.linkroutes",
            .stayLit: "com.andrew.staylit",
            .mixBar: "com.andrew.mixbar",
            .rightHere: "com.andrew.righthere",
            .latent: "com.diamondplated.latent",
            .sift: "io.github.diamondplated.sift",
        ]
        XCTAssertEqual(Set(ManagedApp.allCases), Set(expected.keys))
        for app in ManagedApp.allCases {
            XCTAssertEqual(app.bundleIdentifier, expected[app])
            XCTAssertEqual(app.payloadFilename, app.name + ".app")
        }
    }

    func testOnlyUtilitiesUseTheSettingsBridge() {
        XCTAssertEqual(ManagedApp.allCases.filter(\.supportsSettingsBridge), [.dockPeek, .screenWren, .scrollSplit, .linkRoutes, .stayLit, .mixBar, .rightHere])
        XCTAssertEqual(ManagedApp.allCases.filter { $0.kind == .app }, [.latent, .sift])
    }

    func testEveryAppDescribesItself() {
        for app in ManagedApp.allCases {
            XCTAssertFalse(app.summary.isEmpty)
            XCTAssertFalse(app.onboarding.isEmpty)
        }
    }

    func testLinkRoutesCannotBeRemovedWhileItOwnsLinksOrFileTypes() throws {
        func blocker(_ values: [String: Any]) throws -> String? {
            AppManager.uninstallBlocker(for: .linkRoutes, snapshot: try JSONSerialization.data(withJSONObject: values))
        }
        XCTAssertNil(try blocker(["isDefaultBrowser": false, "takenOverExtensions": [String]()]))
        XCTAssertNil(try blocker(["isDefaultBrowser": false]))
        XCTAssertEqual(try blocker(["isDefaultBrowser": true])?.contains("default browser"), true)
        let files = try XCTUnwrap(try blocker(["isDefaultBrowser": false, "takenOverExtensions": ["md", "csv"]]))
        XCTAssertTrue(files.contains(".csv") && files.contains(".md") && files.contains("Stop Routing Files"))
        // Other apps are never blocked by these keys.
        XCTAssertNil(AppManager.uninstallBlocker(for: .scrollSplit, snapshot: try JSONSerialization.data(withJSONObject: ["isDefaultBrowser": true])))
    }

    func testEveryAppHasAPageLink() {
        for app in ManagedApp.allCases { XCTAssertEqual(ManagedApp(deepLink: app.deepLink), app) }
    }
}
