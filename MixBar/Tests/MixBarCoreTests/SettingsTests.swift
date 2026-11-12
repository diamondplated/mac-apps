import XCTest
@testable import MixBarCore

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MixBarCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func patch(_ json: String) throws -> SettingsPatch { try SettingsPatch(data: Data(json.utf8)) }

    func testDefaultsRememberAndHoldNothing() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, MixBarSettings())
        let snapshot = store.snapshotValues()
        XCTAssertEqual(snapshot["remembersVolumes"] as? Bool, true)
        XCTAssertEqual((snapshot["appVolumes"] as? [Any])?.count, 0)
        XCTAssertEqual(Set(snapshot.keys), ["remembersVolumes", "appVolumes"])
    }

    func testValidPatchWritesEveryKeyAndIgnoresName() throws {
        let store = SettingsStore(defaults: defaults)
        store.write(try patch("""
        {"remembersVolumes":false,"launchAtLogin":true,"appVolumes":[
          {"bundleIdentifier":"com.apple.Music","name":"Ignored","volume":0.25,"muted":true,"outputDeviceUID":"BuiltInSpeakerDevice"},
          {"bundleIdentifier":"com.spotify.client","volume":2,"muted":false,"outputDeviceUID":null},
          {"bundleIdentifier":"us.zoom.xos","volume":0,"muted":false}]}
        """), nameFor: { $0 == "com.apple.Music" ? "Music" : nil })
        let settings = store.settings
        XCTAssertFalse(settings.remembersVolumes)
        XCTAssertEqual(settings.appVolumes, [
            AppVolume(bundleIdentifier: "com.apple.Music", name: "Music", volume: 0.25, muted: true, outputDeviceUID: "BuiltInSpeakerDevice"),
            AppVolume(bundleIdentifier: "com.spotify.client", name: "com.spotify.client", volume: 2),
            AppVolume(bundleIdentifier: "us.zoom.xos", name: "us.zoom.xos", volume: 0)
        ])
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"), "login is not a preference")
        let entry = (store.snapshotValues()["appVolumes"] as? [[String: Any]])?[1]
        XCTAssertTrue(entry?["outputDeviceUID"] is NSNull, "null output reads back as null")
        XCTAssertEqual(entry?["name"] as? String, "com.spotify.client")
    }

    func testKnownNameIsKeptAndShorterListForgets() throws {
        let store = SettingsStore(defaults: defaults)
        store.write(try patch("{\"appVolumes\":[{\"bundleIdentifier\":\"a.b\",\"volume\":0.5,\"muted\":false},{\"bundleIdentifier\":\"c.d\",\"volume\":0.5,\"muted\":false}]}"),
                    nameFor: { _ in "First Name" })
        store.write(try patch("{\"appVolumes\":[{\"bundleIdentifier\":\"a.b\",\"name\":\"Other\",\"volume\":0.7,\"muted\":false}]}"), nameFor: { _ in "Second Name" })
        XCTAssertEqual(store.settings.appVolumes, [AppVolume(bundleIdentifier: "a.b", name: "First Name", volume: 0.7)])
    }

    func testInvalidPatchesAreRejectedWhole() {
        let entry = { (fields: String) in "{\"appVolumes\":[{\(fields)}]}" }
        let hundredOne = (0..<101).map { "{\"bundleIdentifier\":\"app.n\($0)\",\"volume\":1,\"muted\":false}" }.joined(separator: ",")
        let bad = [
            "[]", "null", "{\"remembersVolumes\":1}", "{\"remembersVolumes\":null}", "{\"remembersVolumes\":\"true\"}",
            "{\"appVolumes\":{}}", "{\"appVolumes\":null}", "{\"appVolumes\":[1]}", "{\"appVolumes\":[\(hundredOne)]}",
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":2.01,\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":-0.01,\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":true,\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":\"1\",\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":1"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":1,\"muted\":0"),
            entry("\"bundleIdentifier\":\"a b\",\"volume\":1,\"muted\":false"),
            entry("\"volume\":1,\"muted\":false"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":1,\"muted\":false,\"outputDeviceUID\":\"\""),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":1,\"muted\":false,\"outputDeviceUID\":5"),
            entry("\"bundleIdentifier\":\"a.b\",\"volume\":1,\"muted\":false,\"extra\":true"),
            "{\"appVolumes\":[{\"bundleIdentifier\":\"a.b\",\"volume\":1,\"muted\":false},{\"bundleIdentifier\":\"a.b\",\"volume\":0.5,\"muted\":false}]}",
            "{\"unknown\":true}", "{\"schemaVersion\":1}", "{\"app\":\"mixBar\"}", "{\"loginStatus\":\"enabled\"}",
            "{\"audioControlAvailable\":true}", "{\"audioCaptureStatus\":\"granted\"}", "{\"remembersVolumes\":true,\"audioCaptureStatus\":\"denied\"}"
        ]
        for json in bad { XCTAssertThrowsError(try SettingsPatch(data: Data(json.utf8)), json) }
        for key in SettingsPatch.readOnlyKeys { XCTAssertFalse(SettingsPatch.writableKeys.contains(key), key) }
        XCTAssertThrowsError(try SettingsPatch(data: Data(repeating: 0x20, count: 262_145)))
    }

    func testRejectedPatchWritesNothing() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertThrowsError(try patch("{\"remembersVolumes\":false,\"appVolumes\":[{\"bundleIdentifier\":\"a.b\",\"volume\":9,\"muted\":false}]}"))
        XCTAssertEqual(store.settings, MixBarSettings())
    }

    func testBoundariesAreAccepted() throws {
        let hundred = (0..<100).map { "{\"bundleIdentifier\":\"app.n\($0)\",\"volume\":\($0 % 3),\"muted\":false}" }.joined(separator: ",")
        XCTAssertEqual((try patch("{\"appVolumes\":[\(hundred)]}").values["appVolumes"] as? [AppVolume])?.count, 100)
        XCTAssertEqual((try patch("{\"appVolumes\":[]}").values["appVolumes"] as? [AppVolume])?.count, 0)
        XCTAssertNotNil(try patch("{}"))
    }

    func testStoredJunkIsSanitised() {
        defaults.set([["bundleIdentifier": "ok.app", "volume": 0.5, "muted": false],
                      ["bundleIdentifier": "ok.app", "volume": 0.9, "muted": false],
                      ["bundleIdentifier": "loud.app", "volume": 7, "muted": false],
                      ["bundleIdentifier": "bad id", "volume": 1, "muted": false],
                      "nonsense"] as [Any], forKey: "appVolumes")
        defaults.set("yes", forKey: "remembersVolumes")
        let settings = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(settings.appVolumes.map(\.bundleIdentifier), ["ok.app"])
        XCTAssertEqual(settings.appVolumes.first?.volume, 0.5)
        XCTAssertTrue(settings.remembersVolumes)
    }

    func testMixerWritesThroughTheSamePatch() throws {
        let list = [AppVolume(bundleIdentifier: "com.apple.Music", name: "Music", volume: 1.4, muted: false, outputDeviceUID: "dev")]
        let patch = try SettingsPatch(data: SettingsPatch.data(appVolumes: list))
        XCTAssertEqual((patch.values["appVolumes"] as? [AppVolume])?.first?.volume, 1.4)
    }

    func testNeutralAndGain() {
        XCTAssertTrue(AppVolume(bundleIdentifier: "a.b", name: "").isNeutral)
        XCTAssertFalse(AppVolume(bundleIdentifier: "a.b", name: "", muted: true).isNeutral)
        XCTAssertFalse(AppVolume(bundleIdentifier: "a.b", name: "", outputDeviceUID: "x").isNeutral)
        XCTAssertEqual(AppVolume(bundleIdentifier: "a.b", name: "", volume: 1.5, muted: true).gain, 0)
        XCTAssertEqual(AppVolume(bundleIdentifier: "a.b", name: "", volume: 1.5).gain, 1.5)
    }

    func testSetupIsOfferedOnlyOnTheFirstLaunchWhenAccessIsNeeded() {
        XCTAssertTrue(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: false, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: true, launchedAsLoginItem: false, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: true, needsAccess: true))
        XCTAssertFalse(SetupOffer.shouldOffer(alreadyOffered: false, launchedAsLoginItem: false, needsAccess: false))
    }
}
