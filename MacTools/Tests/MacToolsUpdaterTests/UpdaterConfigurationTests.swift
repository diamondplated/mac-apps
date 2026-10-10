import Foundation
import XCTest
@testable import MacTools

final class UpdaterConfigurationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/Applications/Mac Tools.app")

    private var validInfo: [String: Any] {
        ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.andrew.mactools",
         "CFBundleExecutable": "MacTools", "CFBundleVersion": "2", "CFBundleShortVersionString": "1.1.0",
         "SUFeedURL": "https://downloads.example.com/mac-tools/appcast.xml",
         "SUPublicEDKey": Data((1...32).map(UInt8.init)).base64EncodedString(),
         "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
         "SUSignedFeedFailureExpirationInterval": 0]
    }

    func testValidPackagedConfiguration() {
        XCTAssertNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: validInfo))
    }

    func testMissingMalformedPlaceholderAndZeroKeysDisableUpdates() {
        for key in ["", "REPLACE_WITH_RELEASE_PUBLIC_KEY", "invalid base64", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 0, count: 32).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info), key)
        }
        var info = validInfo
        info.removeValue(forKey: "SUPublicEDKey")
        XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
    }

    func testFeedRequiresHTTPSWithoutEmbeddedCredentials() {
        for feed in ["http://downloads.example.com/appcast.xml", "file:///tmp/appcast.xml", "",
                     "https://user:password@example.com/appcast.xml", "https://user@example.com/appcast.xml",
                     "https://example.com/appcast.xml#untrusted", "https:///appcast.xml"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        }
        for feed in ["https://github.com/example/downloads/releases/latest/download/appcast.xml",
                     "https://downloads.example.com/mac-tools/appcast.xml"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        }
    }

    func testUnsignedOrExpiringFeedConfigurationIsRejected() {
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            var info = validInfo
            info[key] = false
            XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        }
        var info = validInfo
        info["SUSignedFeedFailureExpirationInterval"] = 1_728_000
        XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
    }

    func testInvalidReleaseVersionsAndUnpackagedExecutableAreRejected() {
        for version in ["", "0", "-1", "2beta", "1.0"] {
            var info = validInfo
            info["CFBundleVersion"] = version
            XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        }
        var info = validInfo
        info["CFBundleShortVersionString"] = "1..0"
        XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: URL(fileURLWithPath: "/tmp/MacTools"), info: validInfo))
    }

    func testCheckedInDefaultsUseDailyChecksAndOptInInstallation() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86_400)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUSignedFeedFailureExpirationInterval"] as? Int, 0)
        // A build without release hosting must remain disabled, rather than contacting
        // the private source repository or silently falling back to an unsigned feed.
        if (info["SUFeedURL"] as? String)?.isEmpty == true {
            XCTAssertNotNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
        } else {
            XCTAssertNil(UpdateConfiguration.unavailableReason(bundleURL: bundleURL, info: info))
            XCTAssertNotNil(UpdateConfiguration.trustedHTTPSURL(info["MacToolsReleasesURL"]))
        }
    }

    @MainActor
    func testTestRunnerDoesNotStartAnUpdater() {
        let controller = UpdateController(bundle: .main)
        XCTAssertFalse(controller.isConfigured)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertNotNil(controller.unavailableReason)
    }
}
