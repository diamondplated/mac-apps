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
            .latent: "com.diamondplated.latent",
            .sift: "io.github.diamondplated.sift",
        ]
        XCTAssertEqual(Set(ManagedApp.allCases), Set(expected.keys))
        for app in ManagedApp.allCases {
            XCTAssertEqual(app.bundleIdentifier, expected[app])
            XCTAssertEqual(app.payloadFilename, app.name + ".app")
        }
    }

    func testOnlyMenuBarUtilitiesUseTheSettingsBridge() {
        XCTAssertEqual(ManagedApp.allCases.filter(\.supportsSettingsBridge), [.dockPeek, .screenWren, .scrollSplit, .linkRoutes])
        XCTAssertEqual(ManagedApp.allCases.filter { $0.kind == .app }, [.latent, .sift])
    }

    func testEveryAppDescribesItself() {
        for app in ManagedApp.allCases {
            XCTAssertFalse(app.summary.isEmpty)
            XCTAssertFalse(app.onboarding.isEmpty)
            XCTAssertFalse(app.features.isEmpty)
        }
    }
}
