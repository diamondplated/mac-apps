import XCTest
@testable import RightHereCore

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let terminals = [Terminal(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
                             Terminal(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm")]

    override func setUp() {
        super.setUp()
        suiteName = "RightHereTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func patch(_ json: String) throws -> SettingsPatch { try SettingsPatch(data: Data(json.utf8), availableTerminals: terminals) }

    func testDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, RightHereSettings())
        let snapshot = store.snapshot(availableTerminals: terminals, extensionEnabled: false)
        XCTAssertEqual(snapshot["schemaVersion"] as? Int, 1)
        XCTAssertEqual(snapshot["app"] as? String, "rightHere")
        XCTAssertEqual(snapshot["showsNewFile"] as? Bool, true)
        XCTAssertEqual(snapshot["showsOpenTerminal"] as? Bool, true)
        XCTAssertEqual(snapshot["showsCopyPath"] as? Bool, true)
        XCTAssertEqual(snapshot["newFileExtensions"] as? [String], ["txt", "md"])
        XCTAssertEqual(snapshot["terminalBundleIdentifier"] as? String, "com.apple.Terminal")
        XCTAssertEqual(snapshot["extensionEnabled"] as? Bool, false)
        XCTAssertEqual((snapshot["availableTerminals"] as? [[String: String]])?.map { $0["name"] }, ["Terminal", "iTerm"])
    }

    func testLoginKeysAreFixed() throws {
        let store = SettingsStore(defaults: defaults)
        let snapshot = store.snapshot(availableTerminals: terminals, extensionEnabled: true)
        XCTAssertEqual(snapshot["launchAtLogin"] as? Bool, false)
        XCTAssertEqual(snapshot["loginStatus"] as? String, "notApplicable")
        // false is accepted and changes nothing.
        let accepted = try patch("{\"launchAtLogin\":false}")
        XCTAssertTrue(accepted.values.isEmpty)
        store.write(accepted)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))
        // true is rejected, and takes the whole patch with it.
        XCTAssertThrowsError(try patch("{\"launchAtLogin\":true,\"showsCopyPath\":false}")) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not stay running"))
        }
        XCTAssertThrowsError(try patch("{\"launchAtLogin\":1}"))
        XCTAssertThrowsError(try patch("{\"loginStatus\":\"enabled\"}"), "loginStatus is read-only")
    }

    func testPatchRoundTrip() throws {
        let store = SettingsStore(defaults: defaults)
        store.write(try patch("{\"showsNewFile\":false,\"newFileExtensions\":[\"py\",\"json\",\"x1\"],\"terminalBundleIdentifier\":\"com.googlecode.iterm2\"}"))
        let s = store.settings
        XCTAssertFalse(s.showsNewFile)
        XCTAssertTrue(s.showsOpenTerminal)
        XCTAssertEqual(s.newFileExtensions, ["py", "json", "x1"])
        XCTAssertEqual(s.terminalBundleIdentifier, "com.googlecode.iterm2")
    }

    func testRejectsBadPatchesWithoutWritingAnything() throws {
        let store = SettingsStore(defaults: defaults)
        let bad = [
            "{\"unknown\":true}", "{\"extensionEnabled\":true}", "{\"availableTerminals\":[]}", "{\"schemaVersion\":1}", "{\"app\":\"x\"}",
            "{\"showsNewFile\":1}", "{\"showsNewFile\":null}", "{\"showsCopyPath\":\"yes\"}",
            "{\"newFileExtensions\":[]}", "{\"newFileExtensions\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}",
            "{\"newFileExtensions\":[\"txt\",\"txt\"]}", "{\"newFileExtensions\":[\"TXT\"]}", "{\"newFileExtensions\":[\"\"]}",
            "{\"newFileExtensions\":[\"abcdefghijk\"]}", "{\"newFileExtensions\":[\".txt\"]}", "{\"newFileExtensions\":[\"a/b\"]}",
            "{\"newFileExtensions\":[1]}", "{\"newFileExtensions\":\"txt\"}",
            "{\"terminalBundleIdentifier\":\"com.example.nope\"}", "{\"terminalBundleIdentifier\":3}",
            "[]", "not json"
        ]
        for json in bad { XCTAssertThrowsError(try patch(json), json) }
        // One bad key rejects the whole patch.
        XCTAssertThrowsError(try patch("{\"showsNewFile\":false,\"terminalBundleIdentifier\":\"com.example.nope\"}"))
        XCTAssertEqual(store.settings, RightHereSettings())
        // The boundaries that are allowed.
        XCTAssertNoThrow(try patch("{\"newFileExtensions\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\"]}"))
        XCTAssertNoThrow(try patch("{\"newFileExtensions\":[\"abcdefghij\"]}"))
    }

    func testTerminalFallbackIsReported() {
        let store = SettingsStore(defaults: defaults)
        defaults.set("com.example.uninstalled", forKey: "terminalBundleIdentifier")
        let snapshot = store.snapshot(availableTerminals: terminals, extensionEnabled: false)
        XCTAssertEqual(snapshot["terminalBundleIdentifier"] as? String, "com.apple.Terminal")
        XCTAssertEqual(snapshot["terminalFellBack"] as? Bool, true)
        defaults.set("com.googlecode.iterm2", forKey: "terminalBundleIdentifier")
        let fine = store.snapshot(availableTerminals: terminals, extensionEnabled: false)
        XCTAssertEqual(fine["terminalBundleIdentifier"] as? String, "com.googlecode.iterm2")
        XCTAssertEqual(fine["terminalFellBack"] as? Bool, false)
        XCTAssertEqual(Terminal.resolve(saved: "com.apple.Terminal", available: []).fellBack, false)
    }

    func testAvailableTerminalsComeFromTheKnownList() {
        let found = Terminal.available { $0 == "com.mitchellh.ghostty" || $0 == "com.apple.Terminal" || $0 == "com.example.other" }
        XCTAssertEqual(found.map(\.name), ["Terminal", "Ghostty"])
        XCTAssertEqual(Terminal.known.count, 7)
    }

    func testGarbageInTheDomainFallsBackToDefaults() {
        defaults.set("yes", forKey: "showsNewFile")
        defaults.set(["TXT", "txt"], forKey: "newFileExtensions")
        defaults.set(12, forKey: "terminalBundleIdentifier")
        defaults.set([1, 2], forKey: "showsCopyPath")
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, RightHereSettings())
        defaults.set(Data([0xff, 0x00]), forKey: "showsOpenTerminal")
        XCTAssertTrue(SettingsStore(defaults: defaults).settings.showsOpenTerminal)
    }

    func testTwoHandlesOnOneDomainSeeEachOther() throws {
        // The app writes; the extension reads the same domain through its own handle.
        let writer = SettingsStore(defaults: defaults)
        let reader = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        writer.write(try patch("{\"showsCopyPath\":false}"))
        XCTAssertFalse(reader.settings.showsCopyPath)
        writer.write(try patch("{\"showsCopyPath\":true}"))
        XCTAssertTrue(reader.settings.showsCopyPath)
    }
}
