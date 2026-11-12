import XCTest
@testable import StayLitCore

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StayLitCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAreAllOffAndEmpty() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, StayLitSettings())
        let snapshot = store.snapshotValues()
        XCTAssertEqual(snapshot["keepAwake"] as? Bool, false)
        XCTAssertEqual(snapshot["keepAwakeApps"] as? [String], [])
        XCTAssertEqual(snapshot["keepsDisplayAwake"] as? Bool, false)
        XCTAssertEqual(snapshot["brightnessKeysControlDisplays"] as? Bool, false)
        XCTAssertEqual(snapshot["volumeKeysControlDisplays"] as? Bool, false)
        XCTAssertFalse(StayLitSettings().wantsKeyTap)
    }

    func testValidPatchWritesEveryKey() throws {
        let store = SettingsStore(defaults: defaults)
        let patch = try SettingsPatch(data: Data("""
        {"keepAwake":true,"keepAwakeApps":["com.apple.dt.Xcode","com.apple.dt.Xcode","org.videolan.vlc"],"keepsDisplayAwake":true,
         "brightnessKeysControlDisplays":true,"volumeKeysControlDisplays":true,"launchAtLogin":false}
        """.utf8))
        store.write(patch)
        let settings = store.settings
        XCTAssertTrue(settings.keepAwake)
        XCTAssertEqual(settings.keepAwakeApps, ["com.apple.dt.Xcode", "org.videolan.vlc"], "duplicates collapse, order kept")
        XCTAssertTrue(settings.keepsDisplayAwake)
        XCTAssertTrue(settings.brightnessKeysControlDisplays)
        XCTAssertTrue(settings.volumeKeysControlDisplays)
        XCTAssertTrue(settings.wantsKeyTap)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"), "login is not a preference")
    }

    func testInvalidPatchesAreRejectedWhole() {
        let fifty = (0..<51).map { "\"com.example.app\($0)\"" }.joined(separator: ",")
        let bad = [
            "[]", "null", "{\"keepAwake\":1}", "{\"keepAwake\":null}", "{\"keepAwake\":\"true\"}",
            "{\"keepAwakeApps\":\"com.apple.Safari\"}", "{\"keepAwakeApps\":[1]}", "{\"keepAwakeApps\":[\"\"]}",
            "{\"keepAwakeApps\":[\"has space\"]}", "{\"keepAwakeApps\":[\"../etc\"]}", "{\"keepAwakeApps\":[\(fifty)]}",
            "{\"keepAwakeApps\":null}", "{\"unknown\":true}", "{\"keepAwake\":true,\"awakeReason\":null}",
            "{\"externalDisplays\":[]}", "{\"permissions\":{}}", "{\"permissionsSource\":\"runningApp\"}",
            "{\"schemaVersion\":1}", "{\"app\":\"stayLit\"}", "{\"loginStatus\":\"enabled\"}",
            "{\"keepAwake\":true,\"brightnessKeysControlDisplays\":2}"
        ]
        for json in bad { XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8)), json) }
        for key in SettingsPatch.readOnlyKeys { XCTAssertFalse(SettingsPatch.writableKeys.contains(key), key) }
        XCTAssertThrowsError(try SettingsPatch(data: Data(repeating: 0x20, count: 65_537)))
    }

    func testFiftyAppsAndEmptyListAreAccepted() throws {
        let fifty = (0..<50).map { "\"com.example.app\($0)\"" }.joined(separator: ",")
        XCTAssertEqual((try SettingsPatch(data: Data("{\"keepAwakeApps\":[\(fifty)]}".utf8)).values["keepAwakeApps"] as? [String])?.count, 50)
        XCTAssertEqual(try SettingsPatch(data: Data("{\"keepAwakeApps\":[]}".utf8)).values["keepAwakeApps"] as? [String], [])
        XCTAssertNotNil(try SettingsPatch(data: Data("{}".utf8)))
    }

    func testStoredJunkIsSanitised() {
        defaults.set(["com.ok.app", 7, "bad id", "com.ok.app"] as [Any], forKey: "keepAwakeApps")
        defaults.set("yes", forKey: "keepAwake")
        let settings = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(settings.keepAwakeApps, ["com.ok.app"])
    }

    func testBundleIdentifierRules() {
        XCTAssertTrue(BundleIdentifier.isValid("com.apple.dt.Xcode"))
        XCTAssertTrue(BundleIdentifier.isValid("org.mozilla.firefox_beta-2"))
        XCTAssertFalse(BundleIdentifier.isValid(""))
        XCTAssertFalse(BundleIdentifier.isValid("com/apple"))
        XCTAssertFalse(BundleIdentifier.isValid("com.äpple"))
        XCTAssertFalse(BundleIdentifier.isValid(String(repeating: "a", count: 256)))
    }

    func testSetupIsOfferedOnlyOnTheFirstLaunchWhenAccessIsNeeded() {
        XCTAssertTrue(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: false, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: true, launchedAsLoginItem: false, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: true, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: false, needsAccess: false))
    }
}
