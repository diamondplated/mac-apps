import Foundation
import XCTest
@testable import MacTools

final class NewFeatureSettingsTests: XCTestCase {
    private func snapshot(_ app: String, _ extra: [String: Any] = [:]) throws -> ToolSettingsSnapshot {
        var json: [String: Any] = ["schemaVersion": 1, "app": app, "launchAtLogin": false, "loginStatus": "notRegistered"]
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(ToolSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDockPeekOptionsAreAbsentFromAnOlderAppAndReadFromANewerOne() throws {
        let older = try snapshot("dockPeek")
        XCTAssertNil(older.switcherEnabled)
        XCTAssertNil(older.dockClickHidesFrontApp)
        let newer = try snapshot("dockPeek", ["switcherEnabled": true, "dockClickHidesFrontApp": false,
                                              "dockScrollCyclesWindows": true, "dockMiddleClickOpensWindow": false])
        XCTAssertEqual(newer.switcherEnabled, true)
        XCTAssertEqual(newer.dockClickHidesFrontApp, false)
        XCTAssertEqual(newer.dockScrollCyclesWindows, true)
        XCTAssertEqual(newer.dockMiddleClickOpensWindow, false)
    }

    func testScrollSplitMouseFixesAreAbsentFromAnOlderAppAndReadFromANewerOne() throws {
        let older = try snapshot("scrollSplit", ["enabled": true, "reverseVertical": true])
        XCTAssertFalse(older.hasMouseFixes)
        XCTAssertNil(older.mouseAccelerationAvailable)
        let newer = try snapshot("scrollSplit", ["enabled": true, "smoothScrolling": true, "sideButtonsNavigate": false,
                                                 "mouseAccelerationOff": false, "mouseAccelerationAvailable": false])
        XCTAssertTrue(newer.hasMouseFixes)
        XCTAssertEqual(newer.smoothScrolling, true)
        XCTAssertEqual(newer.sideButtonsNavigate, false)
        XCTAssertEqual(newer.mouseAccelerationAvailable, false)
    }

    func testRoundThreeKeysAreAbsentFromOlderAppsAndReadFromNewerOnes() throws {
        XCTAssertNil(try snapshot("dockPeek").restoresWindowLayouts)
        XCTAssertEqual(try snapshot("dockPeek", ["restoresWindowLayouts": true]).restoresWindowLayouts, true)
        XCTAssertFalse(try snapshot("scrollSplit").hasKeyboardOverrides)
        let keyboard = try snapshot("scrollSplit", ["holdToQuit": true, "capsLockIsHyper": false, "capsLockTapIsEscape": false,
                                                    "capsLockRemapAvailable": false,
                                                    "shortcuts": [["command": "pastePlainText", "title": "Paste as Plain Text", "shortcut": NSNull()]]])
        XCTAssertTrue(keyboard.hasKeyboardOverrides)
        XCTAssertEqual(keyboard.capsLockRemapAvailable, false)
        XCTAssertEqual(keyboard.shortcuts?.first?.command, "pastePlainText")
        XCTAssertNil(keyboard.shortcuts?.first?.shortcut)
        XCTAssertNil(try snapshot("linkRoutes").fileRules)
        let files = try snapshot("linkRoutes", ["fileRules": [["id": "1", "fileExtension": "md", "folder": "~/Notes", "applicationIdentifier": "com.example.editor"]],
                                                "takenOverExtensions": ["md"]])
        XCTAssertEqual(files.fileRules?.first?.folder, "~/Notes")
        XCTAssertEqual(files.takenOverExtensions, ["md"])
    }

    func testStayLitSnapshotIsRead() throws {
        let value = try snapshot("stayLit", ["keepAwake": true, "keepAwakeApps": ["com.apple.dt.Xcode"], "keepsDisplayAwake": false,
                                             "brightnessKeysControlDisplays": true, "volumeKeysControlDisplays": false,
                                             "awakeReason": "Awake while Xcode is running",
                                             "externalDisplays": [["name": "Studio Monitor", "controllable": true]],
                                             "permissions": ["accessibility": true], "permissionsSource": "runningApp"])
        XCTAssertEqual(value.keepAwakeApps, ["com.apple.dt.Xcode"])
        XCTAssertEqual(value.awakeReason, "Awake while Xcode is running")
        XCTAssertEqual(value.externalDisplays, [ExternalDisplay(name: "Studio Monitor", controllable: true)])
        XCTAssertEqual(value.permission("accessibility"), true)
        let idle = try snapshot("stayLit", ["keepAwake": false, "keepAwakeApps": [String](), "awakeReason": NSNull()])
        XCTAssertNil(idle.awakeReason)
        XCTAssertNil(idle.externalDisplays)
    }

    func testRoundFourKeysAreAbsentFromOlderAppsAndReadFromNewerOnes() throws {
        XCTAssertFalse(try snapshot("scrollSplit").hasKeyboardOverrides)
        let cut = try snapshot("scrollSplit", ["cutAndPasteFilesInFinder": false])
        XCTAssertTrue(cut.hasKeyboardOverrides)
        XCTAssertNil(cut.capsLockIsHyper)
        XCTAssertTrue(cut.canOpenAtLogin)
    }

    func testMixBarSnapshotIsReadAndAnEntryIsWrittenBackWithoutItsName() throws {
        let value = try snapshot("mixBar", ["remembersVolumes": true, "audioControlAvailable": true, "audioCaptureStatus": "granted",
                                            "appVolumes": [["bundleIdentifier": "com.example.music", "name": "Music", "volume": 0.654, "muted": false, "outputDeviceUID": NSNull()],
                                                           ["bundleIdentifier": "com.example.calls", "name": "", "volume": 1.5, "muted": true, "outputDeviceUID": "Speakers-1"]]])
        let entries = try XCTUnwrap(value.appVolumes)
        XCTAssertEqual(entries.map(\.summary), ["65%", "Muted, own output"])
        XCTAssertEqual(entries[0].displayName, "Music")
        XCTAssertEqual(value.audioCaptureStatus, "granted")
        let patch = entries[0].patch
        XCTAssertEqual(Set(patch.keys), ["bundleIdentifier", "volume", "muted", "outputDeviceUID"])
        XCTAssertTrue(patch["outputDeviceUID"] is NSNull)
        XCTAssertEqual(entries[1].patch["outputDeviceUID"] as? String, "Speakers-1")
        // The whole patch must survive JSON encoding, null included.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["appVolumes": entries.map(\.patch)]))
        XCTAssertNil(try snapshot("mixBar").appVolumes)
    }

    func testRightHereSnapshotIsReadAndHasNothingToOpenAtLogin() throws {
        let value = try snapshot("rightHere", ["loginStatus": "notApplicable", "showsNewFile": true, "showsOpenTerminal": false, "showsCopyPath": true,
                                               "newFileExtensions": ["txt", "md"], "terminalBundleIdentifier": "com.apple.Terminal",
                                               "availableTerminals": [["bundleIdentifier": "com.apple.Terminal", "name": "Terminal"]],
                                               "extensionEnabled": false])
        XCTAssertFalse(value.canOpenAtLogin)
        XCTAssertEqual(value.showsOpenTerminal, false)
        XCTAssertEqual(value.availableTerminals, [TerminalApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal")])
        XCTAssertEqual(value.extensionEnabled, false)
    }

    func testNewFileTypesAreTidiedAndRefusedForTheRightReasons() throws {
        XCTAssertEqual(NewFileTypes.cleaned(" .CSV "), "csv")
        XCTAssertEqual(NewFileTypes.cleaned("*.json5"), "json5")
        for bad in ["", ".", "tar.gz", "a b", "über", "abcdefghijk", "../x"] { XCTAssertNil(NewFileTypes.cleaned(bad), bad) }
        XCTAssertEqual(try NewFileTypes.adding(".PY", to: ["txt"]).get(), ["txt", "py"])
        XCTAssertThrowsError(try NewFileTypes.adding("TXT", to: ["txt"]).get())
        XCTAssertThrowsError(try NewFileTypes.adding("no good", to: ["txt"]).get())
        XCTAssertThrowsError(try NewFileTypes.adding("h", to: ["a", "b", "c", "d", "e", "f", "g", "i"]).get())
        XCTAssertEqual(["txt", "md", "py"].map(NewFileTypes.title(for:)), ["Text File", "Markdown File", "PY File"])
    }

    func testAFileRuleIsTidiedBeforeItIsSaved() throws {
        let rule = FileRouteRule(id: "1", fileExtension: " *.MD ", folder: "   ", applicationIdentifier: "com.example.editor")
        let ready = rule.readyToSave
        XCTAssertEqual(ready.fileExtension, "md")
        XCTAssertNil(ready.folder)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "fileExtension", "applicationIdentifier"])
        XCTAssertEqual(FileRouteRule(id: "2", fileExtension: "csv", folder: " /Volumes/Data ", applicationIdentifier: "x").readyToSave.folder, "/Volumes/Data")
    }

    func testFoldersAreShownRelativeToHome() {
        XCTAssertEqual(FileApps.display(folder: nil), "Any folder")
        XCTAssertEqual(FileApps.display(folder: "/Users/someone/Notes/Work", home: "/Users/someone"), "~/Notes/Work")
        XCTAssertEqual(FileApps.display(folder: "/Users/someone", home: "/Users/someone"), "~")
        XCTAssertEqual(FileApps.display(folder: "/Users/someoneelse/Notes", home: "/Users/someone"), "/Users/someoneelse/Notes")
    }

    @MainActor
    func testFileRuleDraftsSurviveARefreshAndKeepEditsMadeDuringASave() throws {
        let model = ToolSettingsModel()
        let saved = FileRouteRule(id: "1", fileExtension: "md", applicationIdentifier: "a")
        model.synchronizeFileRuleDraft([saved])
        model.fileRules.append(FileRouteRule(id: "2", fileExtension: "csv", applicationIdentifier: "b"))
        let sent = model.fileRules
        model.synchronizeFileRuleDraft([saved])
        XCTAssertEqual(model.fileRules.count, 2)
        model.fileRules[1].fileExtension = "tsv"
        model.fileRulesSaved(sent, sent: sent)
        XCTAssertEqual(model.fileRules[1].fileExtension, "tsv")
        XCTAssertTrue(model.hasUnsavedFileRules)
        model.discardFileRuleChanges()
        XCTAssertEqual(model.fileRules, sent)
    }

    func testSourceRulesAreOfferedOnlyWhenLinkRoutesReportsLinkCleaning() throws {
        XCTAssertFalse(try snapshot("linkRoutes").supportsSourceRules)
        let newer = try snapshot("linkRoutes", ["stripsTrackingParameters": true, "unwrapsRedirects": false])
        XCTAssertTrue(newer.supportsSourceRules)
        XCTAssertEqual(newer.unwrapsRedirects, false)
    }

    func testARuleWithoutASourceAppIsWrittenExactlyAsBefore() throws {
        let rule = BrowserRouteRule(id: "1", domain: "example.com", browserIdentifier: "com.apple.Safari")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule.readyToSave)) as? [String: Any])
        // An older LinkRoutes validates every key, so the new one must not appear at all.
        XCTAssertEqual(Set(json.keys), ["id", "domain", "includeSubdomains", "browserIdentifier"])
    }

    func testARuleForEveryWebsiteFromOneAppIsWrittenWithTheWildcardAndShownEmpty() throws {
        var rule = BrowserRouteRule(id: "1", domain: "  ", browserIdentifier: "com.google.Chrome", profileDirectory: "Profile 1",
                                    sourceBundleIdentifier: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(rule.readyToSave.domain, "*")
        let data = try JSONEncoder().encode(rule.readyToSave)
        let stored = try JSONDecoder().decode(BrowserRouteRule.self, from: data)
        XCTAssertEqual(stored.sourceBundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(stored.websiteText, "")
        // Typing a website narrows the rule again.
        rule.websiteText = "github.com"
        XCTAssertEqual(rule.readyToSave.domain, "github.com")
    }

    func testRemovingTheSourceAppDoesNotLeaveAWildcardBehind() {
        var rule = BrowserRouteRule(id: "1", domain: "*", browserIdentifier: "com.apple.Safari", sourceBundleIdentifier: "com.apple.MobileSMS")
        rule.sourceBundleIdentifier = nil
        XCTAssertEqual(rule.readyToSave.domain, "")
        rule.sourceBundleIdentifier = ""
        XCTAssertNil(rule.readyToSave.sourceBundleIdentifier)
    }

    func testSourceAppChoicesAreSortedDeduplicatedAndKeepAnAppThatIsNotOpen() {
        let running = [SourceApp(identifier: "com.tinyspeck.slackmacgap", name: "Slack"),
                       SourceApp(identifier: "com.apple.MobileSMS", name: "Messages"),
                       SourceApp(identifier: "com.apple.MobileSMS", name: "Messages"),
                       SourceApp(identifier: "com.andrew.linkroutes", name: "LinkRoutes")]
        let choices = SourceApps.choices(running: running, current: "com.microsoft.Outlook",
                                         excluding: ["com.andrew.linkroutes"]) { _ in "Outlook" }
        XCTAssertEqual(choices.map(\.name), ["Messages", "Outlook", "Slack"])
        let none = SourceApps.choices(running: running, current: nil, excluding: []) { $0 }
        XCTAssertEqual(none.count, 3)
    }
}
