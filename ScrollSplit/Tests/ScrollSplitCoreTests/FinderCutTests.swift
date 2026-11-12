import XCTest
import CoreGraphics
@testable import ScrollSplitCore

final class FinderCutTests: XCTestCase {
    private let finder = FinderCut.finderBundleIdentifier
    private let x = FinderCut.xKeyCode
    private let v = FinderCut.vKeyCode

    private func press(_ cut: inout FinderCut, key: Int64, flags: CGEventFlags = .maskCommand, isRepeat: Bool = false,
                       enabled: Bool = true, own: Bool = false, app: String? = "com.apple.finder",
                       count: Int = 100, focus: FinderCut.Focus = .notText) -> FinderCut.Action {
        cut.keyDown(keyCode: key, flags: flags, isRepeat: isRepeat, enabled: enabled, isOwnEvent: own,
                    frontmostBundleIdentifier: app, changeCount: count, focus: { focus })
    }

    /// ⌘X in Finder, settled with the clipboard at `after`.
    private func cutFiles(_ cut: inout FinderCut, before: Int = 100, after: Int = 101) {
        guard case .copy(let generation, let was) = press(&cut, key: x, count: before) else { return XCTFail("⌘X was not claimed") }
        XCTAssertEqual(cut.keyUp(keyCode: x), .swallow)
        cut.copyFinished(generation: generation, changeCountBefore: was, changeCountNow: after)
    }

    func testCutThenPasteMovesOnce() {
        var cut = FinderCut()
        XCTAssertEqual(press(&cut, key: x, count: 100), .copy(generation: 1, changeCountBefore: 100))
        XCTAssertEqual(cut.keyUp(keyCode: x), .swallow)
        XCTAssertNil(cut.pending, "not remembered until the copy has settled")
        cut.copyFinished(generation: 1, changeCountBefore: 100, changeCountNow: 101)
        XCTAssertEqual(cut.pending, 101)
        XCTAssertEqual(press(&cut, key: v, count: 101), .move)
        XCTAssertEqual(cut.keyUp(keyCode: v), .swallow)
        XCTAssertEqual(press(&cut, key: v, count: 101), .pass, "a cut is used once")
        XCTAssertEqual(cut.keyUp(keyCode: v), .pass)
    }

    func testPasteWithoutACutIsUntouched() {
        var cut = FinderCut()
        XCTAssertEqual(press(&cut, key: v), .pass)
    }

    func testAChangedClipboardForgetsTheCut() {
        var cut = FinderCut()
        cutFiles(&cut)
        XCTAssertEqual(press(&cut, key: v, count: 102), .pass, "someone else copied")
        XCTAssertNil(cut.pending)
        XCTAssertEqual(press(&cut, key: v, count: 101), .pass, "and it stays forgotten even if the count is seen again")
    }

    func testACopyThatChangedNothingIsNotRemembered() {
        var cut = FinderCut()
        cutFiles(&cut, before: 100, after: 100) // empty selection: Finder copied nothing
        XCTAssertNil(cut.pending)
        XCTAssertEqual(press(&cut, key: v, count: 100), .pass)
    }

    func testASecondCutReplacesTheFirstAndAStaleSettleIsIgnored() {
        var cut = FinderCut()
        guard case .copy(let first, let before1) = press(&cut, key: x, count: 100) else { return XCTFail() }
        guard case .copy(let second, let before2) = press(&cut, key: x, count: 101) else { return XCTFail() }
        cut.copyFinished(generation: first, changeCountBefore: before1, changeCountNow: 101)
        XCTAssertNil(cut.pending, "the first copy's timer is stale")
        cut.copyFinished(generation: second, changeCountBefore: before2, changeCountNow: 102)
        XCTAssertEqual(cut.pending, 102)
    }

    func testTextFieldsTimeoutsAndErrorsPassBothKeys() {
        for answer in [FinderCut.Focus.text, .timeout, .error] {
            var cut = FinderCut()
            XCTAssertEqual(press(&cut, key: x, focus: answer), .pass, "⌘X with \(answer)")
            XCTAssertEqual(cut.keyUp(keyCode: x), .pass)
            cutFiles(&cut)
            XCTAssertEqual(press(&cut, key: v, count: 101, focus: answer), .pass, "⌘V with \(answer)")
            XCTAssertEqual(cut.pending, 101, "typing text does not use up the cut")
            XCTAssertEqual(press(&cut, key: v, count: 101), .move)
        }
    }

    func testFocusRolesAreMapped() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"] {
            XCTAssertEqual(FinderCut.Focus.from(role: role), .text, role)
        }
        for role in ["AXOutline", "AXList", "AXBrowser", "AXScrollArea", "AXGroup", "AXRow", "AXImage"] {
            XCTAssertEqual(FinderCut.Focus.from(role: role), .notText, role)
        }
        XCTAssertEqual(FinderCut.Focus.from(role: nil), .error)
    }

    func testOnlyFinderIsAffected() {
        for app in [nil, "com.apple.Safari", "com.apple.finder.Helper", "com.example.Finder"] {
            var cut = FinderCut()
            XCTAssertEqual(press(&cut, key: x, app: app), .pass, app ?? "nil")
            cutFiles(&cut)
            XCTAssertEqual(press(&cut, key: v, app: app, count: 101), .pass, app ?? "nil")
            XCTAssertEqual(cut.pending, 101, "a paste elsewhere leaves the cut alone")
        }
    }

    func testOtherKeysAndExtraModifiersPassThrough() {
        var cut = FinderCut()
        for key in [Int64(0), 8, 6, 12, 36] { XCTAssertEqual(press(&cut, key: key), .pass, "key \(key)") }
        for flags: CGEventFlags in [[], .maskShift, .maskControl, .maskAlternate, [.maskCommand, .maskShift],
                                    [.maskCommand, .maskAlternate], [.maskCommand, .maskControl],
                                    [.maskCommand, .maskControl, .maskAlternate, .maskShift]] {
            XCTAssertEqual(press(&cut, key: x, flags: flags), .pass)
        }
        cutFiles(&cut)
        for flags: CGEventFlags in [[], .maskShift, [.maskCommand, .maskAlternate], [.maskCommand, .maskShift]] {
            XCTAssertEqual(press(&cut, key: v, flags: flags, count: 101), .pass)
        }
        XCTAssertEqual(cut.pending, 101)
    }

    func testCapsLockAndFnDoNotCountAsModifiers() {
        var cut = FinderCut()
        XCTAssertEqual(press(&cut, key: x, flags: [.maskCommand, .maskAlphaShift, .maskSecondaryFn]), .copy(generation: 1, changeCountBefore: 100))
    }

    func testOwnPostedEventsAreIgnored() {
        var cut = FinderCut()
        XCTAssertEqual(press(&cut, key: x, own: true), .pass)
        cutFiles(&cut)
        XCTAssertEqual(press(&cut, key: v, own: true, count: 101), .pass)
        XCTAssertEqual(cut.pending, 101)
    }

    func testSwitchingOffForgetsTheCutAndPassesEverything() {
        var cut = FinderCut()
        cutFiles(&cut)
        XCTAssertEqual(press(&cut, key: v, enabled: false, count: 101), .pass)
        XCTAssertNil(cut.pending)
        XCTAssertEqual(press(&cut, key: v, count: 101), .pass, "turning it back on does not revive the cut")
        XCTAssertEqual(press(&cut, key: x, enabled: false), .pass)
    }

    func testResetForgetsTheCutAndCancelsAPendingCopy() {
        var cut = FinderCut()
        guard case .copy(let generation, let before) = press(&cut, key: x, count: 100) else { return XCTFail() }
        cut.reset()
        cut.copyFinished(generation: generation, changeCountBefore: before, changeCountNow: 101)
        XCTAssertNil(cut.pending)
        cutFiles(&cut)
        cut.reset()
        XCTAssertNil(cut.pending)
        XCTAssertEqual(cut.keyUp(keyCode: x), .pass)
    }

    func testRepeatsOfAClaimedKeyAreSwallowedAndUnclaimedRepeatsPass() {
        var cut = FinderCut()
        XCTAssertEqual(press(&cut, key: x, isRepeat: true), .pass, "a repeat we never claimed")
        _ = press(&cut, key: x)
        XCTAssertEqual(press(&cut, key: x, isRepeat: true), .swallow, "no second copy while held")
        XCTAssertEqual(cut.keyUp(keyCode: x), .swallow)
        cutFiles(&cut)
        XCTAssertEqual(press(&cut, key: v, count: 101), .move)
        XCTAssertEqual(press(&cut, key: v, isRepeat: true, count: 101), .swallow, "holding ⌘V never turns into a copy")
    }

    func testTheFocusQueryRunsOnlyWhenItMatters() {
        var cut = FinderCut()
        var asked = 0
        func run(_ key: Int64, app: String? = finder, flags: CGEventFlags = .maskCommand, enabled: Bool = true) {
            _ = cut.keyDown(keyCode: key, flags: flags, isRepeat: false, enabled: enabled, isOwnEvent: false,
                            frontmostBundleIdentifier: app, changeCount: 100, focus: { asked += 1; return .notText })
        }
        run(v) // no cut pending
        run(x, app: "com.apple.Safari")
        run(x, flags: [.maskCommand, .maskShift])
        run(0)
        run(x, enabled: false)
        XCTAssertEqual(asked, 0)
        run(x)
        XCTAssertEqual(asked, 1)
    }

    // MARK: Settings

    func testTheSwitchDefaultsOffAndIsAValidatedBoolean() throws {
        var settings = ScrollSettings()
        XCTAssertFalse(settings.cutAndPasteFilesInFinder)
        XCTAssertTrue(SettingsPatch.booleanKeys.contains("cutAndPasteFilesInFinder"))
        for bad in ["1", "null", "\"true\"", "0"] {
            XCTAssertThrowsError(try SettingsPatch(data: Data("{\"cutAndPasteFilesInFinder\":\(bad)}".utf8)), bad)
        }
        XCTAssertThrowsError(try SettingsPatch(data: Data("{\"cutAndPasteFilesInFinder\":true,\"nope\":true}".utf8)), "whole patch validated")
        for value in [true, false] {
            let patch = try SettingsPatch(data: Data("{\"cutAndPasteFilesInFinder\":\(value)}".utf8))
            XCTAssertEqual(patch.values["cutAndPasteFilesInFinder"] as? Bool, value)
        }
        XCTAssertNoThrow(try SettingsPatch(data: Data("{\"cutAndPasteFilesInFinder\":true}".utf8), mouseAccelerationAvailable: false, capsLockRemapAvailable: false))

        settings.cutAndPasteFilesInFinder = true
        XCTAssertFalse(settings.needsKeyTap, "the master switch is off")
        settings.enabled = true
        XCTAssertTrue(settings.needsKeyTap, "this switch alone installs the tap")
        settings.cutAndPasteFilesInFinder = false
        XCTAssertFalse(settings.needsKeyTap, "and turning it off removes the tap")
    }

    func testTheSettingRoundTripsThroughAnInjectedDefaultsSuite() throws {
        let name = "scrollsplit.findercut.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(defaults.bool(forKey: "cutAndPasteFilesInFinder"))
        let patch = try SettingsPatch(data: Data("{\"cutAndPasteFilesInFinder\":true}".utf8))
        for (key, value) in patch.values { defaults.set(value, forKey: key) }
        XCTAssertTrue(defaults.bool(forKey: "cutAndPasteFilesInFinder"))
    }
}
