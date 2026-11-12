import XCTest
import AppKit
import SwiftUI
import CoreGraphics
@testable import ScrollSplitCore

// MARK: Hold ⌘Q to quit

final class HoldToQuitTests: XCTestCase {
    private let safari = QuitTarget(pid: 42, bundleIdentifier: "com.apple.Safari")

    private func down(_ gate: inout HoldToQuitGate, key: Int64 = 12, flags: CGEventFlags = .maskCommand, repeat isRepeat: Bool = false,
                      enabled: Bool = true, at now: Double = 0, target: QuitTarget? = nil, own: String? = "com.andrew.scrollsplit",
                      menuOpen: Bool = false) -> HoldToQuitGate.Action {
        gate.keyDown(keyCode: key, flags: flags, isRepeat: isRepeat, enabled: enabled, now: now,
                     frontmost: target ?? safari, ownBundleIdentifier: own, ownMenuOpen: menuOpen)
    }

    func testFullHoldQuitsOnlyTheAppThatWasFrontmostAndSwallowsTheRelease() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertNil(gate.tick(now: 0.79), "not before the ring fills")
        XCTAssertEqual(gate.tick(now: HoldToQuitGate.holdDuration), safari)
        XCTAssertNil(gate.tick(now: 2), "quits once")
        XCTAssertEqual(down(&gate, repeat: true, at: 0.9), .swallow, "repeats after the quit are swallowed")
        XCTAssertEqual(gate.keyUp(keyCode: 12), .swallow)
        XCTAssertEqual(down(&gate, at: 3), .begin(safari), "the next press starts over")
    }

    func testEarlyReleaseClosesThePanelAndQuitsNothing() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertEqual(gate.keyUp(keyCode: 12), .cancel(passEvent: false))
        XCTAssertNil(gate.tick(now: 5))
        XCTAssertFalse(gate.isHolding)
    }

    func testRepeatsWhileHoldingAreSwallowedAndDoNotRestartTheHold() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate, at: 0), .begin(safari))
        for time in stride(from: 0.1, to: 0.7, by: 0.05) { XCTAssertEqual(down(&gate, repeat: true, at: time), .swallow) }
        XCTAssertEqual(gate.tick(now: 0.8), safari, "measured from the first press")
    }

    func testARepeatWithNoHoldInProgressNeverQuits() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate, repeat: true), .swallow)
        XCTAssertNil(gate.tick(now: 5))
    }

    func testADifferentKeyOrModifierDuringTheHoldCancelsAndPassesIt() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertEqual(down(&gate, key: 13), .cancel(passEvent: true), "⌘W goes through")
        XCTAssertNil(gate.tick(now: 1))
        XCTAssertEqual(gate.keyUp(keyCode: 12), .pass, "the cancelled press's release is not claimed")

        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertEqual(gate.flagsChanged([.maskCommand, .maskShift]), .cancel(passEvent: true), "⌘⇧Q is not ⌘Q")
        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertEqual(gate.flagsChanged([]), .cancel(passEvent: true), "releasing ⌘ ends it")
        XCTAssertEqual(gate.flagsChanged([]), .pass)
    }

    func testOnlyPlainCommandQIsClaimed() {
        var gate = HoldToQuitGate()
        for flags: CGEventFlags in [[], .maskShift, [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl], HyperKey.flags] {
            XCTAssertEqual(down(&gate, flags: flags), .pass, "\(flags)")
        }
        XCTAssertEqual(down(&gate, flags: [.maskCommand, .maskAlphaShift, .maskSecondaryFn]), .begin(safari), "Caps Lock and Fn are ignored")
    }

    func testExemptAppsOwnMenuAndSwitchOffPassCommandQ() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate, target: QuitTarget(pid: 1, bundleIdentifier: "com.apple.finder")), .pass)
        XCTAssertEqual(down(&gate, target: QuitTarget(pid: 2, bundleIdentifier: "com.andrew.scrollsplit")), .pass)
        XCTAssertEqual(down(&gate, menuOpen: true), .pass, "Quit ScrollSplit in its own menu")
        XCTAssertEqual(down(&gate, enabled: false), .pass)
        XCTAssertEqual(gate.keyDown(keyCode: 12, flags: .maskCommand, isRepeat: false, enabled: true, now: 0,
                                    frontmost: nil, ownBundleIdentifier: nil, ownMenuOpen: false), .pass, "no frontmost app")
        XCTAssertEqual(down(&gate, target: QuitTarget(pid: 3, bundleIdentifier: nil)), .begin(QuitTarget(pid: 3, bundleIdentifier: nil)))
    }

    func testSwitchingOffMidHoldCancels() {
        var gate = HoldToQuitGate()
        XCTAssertEqual(down(&gate), .begin(safari))
        XCTAssertEqual(down(&gate, repeat: true, enabled: false), .cancel(passEvent: true))
        XCTAssertNil(gate.tick(now: 1))
        _ = down(&gate)
        gate.reset()
        XCTAssertNil(gate.tick(now: 1))
    }
}

// MARK: Caps Lock as Hyper

final class HyperKeyTests: XCTestCase {
    private let f18 = HyperKey.f18KeyCode

    func testHeldCapsLockAddsHyperToOtherKeysAndIsSwallowed() {
        var hyper = HyperKey()
        XCTAssertEqual(hyper.key(keyCode: 4, isDown: true, now: 0, tapIsEscape: false), .pass, "nothing held")
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: true, now: 1, tapIsEscape: false), .swallow)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: true, now: 1.4, tapIsEscape: false), .swallow, "repeat")
        XCTAssertEqual(hyper.key(keyCode: 4, isDown: true, now: 1.5, tapIsEscape: false), .addHyper)
        XCTAssertEqual(hyper.key(keyCode: 4, isDown: false, now: 1.6, tapIsEscape: false), .addHyper)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 2, tapIsEscape: false), .swallow)
        XCTAssertEqual(hyper.key(keyCode: 4, isDown: true, now: 2.1, tapIsEscape: false), .pass)
        XCTAssertEqual(HyperKey.flags, [.maskControl, .maskAlternate, .maskShift, .maskCommand])
    }

    func testLoneQuickTapSendsEscapeOnlyWhenSwitchedOn() {
        var hyper = HyperKey()
        _ = hyper.key(keyCode: f18, isDown: true, now: 0, tapIsEscape: true)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 0.15, tapIsEscape: true), .sendEscape)
        _ = hyper.key(keyCode: f18, isDown: true, now: 1, tapIsEscape: false)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 1.15, tapIsEscape: false), .swallow, "off: a lone tap does nothing")
    }

    func testTapTimingAndUseWithAnotherKey() {
        var hyper = HyperKey()
        _ = hyper.key(keyCode: f18, isDown: true, now: 0, tapIsEscape: true)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: HyperKey.tapLimit, tapIsEscape: true), .sendEscape, "at the limit")
        _ = hyper.key(keyCode: f18, isDown: true, now: 1, tapIsEscape: true)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 1 + HyperKey.tapLimit + 0.01, tapIsEscape: true), .swallow, "too slow")
        _ = hyper.key(keyCode: f18, isDown: true, now: 2, tapIsEscape: true)
        _ = hyper.key(keyCode: f18, isDown: true, now: 2.25, tapIsEscape: true) // a repeat keeps the first press time
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 2.35, tapIsEscape: true), .swallow)
        _ = hyper.key(keyCode: f18, isDown: true, now: 3, tapIsEscape: true)
        _ = hyper.key(keyCode: 4, isDown: true, now: 3.05, tapIsEscape: true)
        _ = hyper.key(keyCode: 4, isDown: false, now: 3.08, tapIsEscape: true)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 3.1, tapIsEscape: true), .swallow, "used as Hyper, not a tap")
        _ = hyper.key(keyCode: f18, isDown: true, now: 4, tapIsEscape: true)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 4.1, tapIsEscape: true), .sendEscape, "the next tap is clean")
    }

    func testAReleaseWithNoPressNeverSendsEscape() {
        var hyper = HyperKey()
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 0, tapIsEscape: true), .swallow)
        _ = hyper.key(keyCode: f18, isDown: true, now: 1, tapIsEscape: true)
        hyper.reset()
        XCTAssertFalse(hyper.isHeld)
        XCTAssertEqual(hyper.key(keyCode: f18, isDown: false, now: 1.1, tapIsEscape: true), .swallow)
    }
}

// MARK: Caps Lock mapping

final class KeyMappingTests: XCTestCase {
    private let ours = KeyMappingEntry.capsLockToF18
    private let rightOptionToCommand = KeyMappingEntry(source: 0x7_0000_00E6, destination: 0x7_0000_00E7)
    private let capsToControl = KeyMappingEntry(source: KeyMappingEntry.capsLock, destination: 0x7_0000_00E0)

    func testAddingKeepsOtherMappingsAndRemovingTakesOutOnlyOurs() throws {
        var ledger = KeyMappingLedger()
        let added = try XCTUnwrap(ledger.adding(device: 1, current: [rightOptionToCommand]))
        XCTAssertEqual(added, [rightOptionToCommand, ours])
        XCTAssertNil(ledger.adding(device: 1, current: added), "reapplying on wake writes nothing")
        XCTAssertEqual(ledger.removing(device: 1, current: added), [rightOptionToCommand])
    }

    func testADisplacedCapsLockMappingComesBack() throws {
        var ledger = KeyMappingLedger()
        let added = try XCTUnwrap(ledger.adding(device: 1, current: [capsToControl, rightOptionToCommand]))
        XCTAssertEqual(added, [rightOptionToCommand, ours])
        _ = ledger.adding(device: 1, current: added) // a later sighting must not record ours as theirs
        XCTAssertEqual(ledger.removing(device: 1, current: added), [rightOptionToCommand, capsToControl])
    }

    func testAReappliedMappingPutsBackWhatItLastDisplaced() throws {
        var ledger = KeyMappingLedger()
        _ = try XCTUnwrap(ledger.adding(device: 1, current: [capsToControl]))
        // Something else replaced the mapping while ScrollSplit was on; the next wake reapplies.
        let capsToOption = KeyMappingEntry(source: KeyMappingEntry.capsLock, destination: 0x7_0000_00E2)
        let again = try XCTUnwrap(ledger.adding(device: 1, current: [capsToOption]))
        XCTAssertEqual(ledger.removing(device: 1, current: again), [capsToOption])
        let cleared = try XCTUnwrap(ledger.adding(device: 1, current: [rightOptionToCommand]))
        XCTAssertEqual(ledger.removing(device: 1, current: cleared), [rightOptionToCommand], "nothing stale comes back")
    }

    func testAUserOwnCapsLockToF18AndUntouchedDevicesAreLeftAlone() {
        var ledger = KeyMappingLedger()
        XCTAssertNil(ledger.adding(device: 1, current: [ours]), "the user's own Hyper setup")
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertNil(ledger.removing(device: 1, current: [ours]))
        XCTAssertNil(ledger.removing(device: 2, current: [ours]))
    }

    func testAMappingAlreadyGoneIsNotRewritten() throws {
        var ledger = KeyMappingLedger()
        _ = try XCTUnwrap(ledger.adding(device: 1, current: [capsToControl]))
        // After a reboot or replug the device came back without either mapping.
        XCTAssertNil(ledger.removing(device: 1, current: []))
        XCTAssertNil(ledger.removing(device: 1, current: [rightOptionToCommand]))
    }

    func testLedgerSurvivesEncodingForCrashRecovery() throws {
        var ledger = KeyMappingLedger()
        _ = ledger.adding(device: 9, current: [capsToControl])
        let decoded = try JSONDecoder().decode(KeyMappingLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.removing(device: 9, current: [ours]), [capsToControl])
        ledger.clear()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testParsingThePropertyRoundTripsAndRejectsWhatItCannotRead() throws {
        XCTAssertEqual(KeyMappingEntry.parse(nil), [])
        let property = KeyMappingEntry.property([rightOptionToCommand, ours])
        XCTAssertEqual(KeyMappingEntry.parse(property as NSArray), [rightOptionToCommand, ours])
        XCTAssertEqual(property[1][KeyMappingEntry.sourceKey]?.uint64Value, 0x7_0000_0039)
        XCTAssertEqual(property[1][KeyMappingEntry.destinationKey]?.uint64Value, 0x7_0000_006D)
        XCTAssertNil(KeyMappingEntry.parse([["HIDKeyboardModifierMappingSrc": 1]] as NSArray))
        XCTAssertNil(KeyMappingEntry.parse("junk"))
    }
}

// MARK: Paste as plain text

private final class FakePasteboard: PasteboardAccess {
    var items: [[PasteboardEntry]]
    var changeCount = 0
    var replaced = 0
    init(_ items: [[PasteboardEntry]]) { self.items = items }

    func plainText() -> String? {
        items.lazy.flatMap { $0 }.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
    func contents() -> [[PasteboardEntry]] { items }
    func replace(withText text: String) -> Int {
        replaced += 1
        items = [[PasteboardEntry(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]]
        changeCount += 1
        return changeCount
    }
    func restore(_ items: [[PasteboardEntry]]) -> Int { self.items = items; changeCount += 1; return changeCount }
    /// Another app copying something.
    func externalWrite(_ text: String) { _ = replace(withText: text); replaced -= 1 }
}

final class PlainPasteTests: XCTestCase {
    private let rich = [[PasteboardEntry(type: "public.rtf", data: Data("{\\rtf1 bold}".utf8)),
                         PasteboardEntry(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("bold".utf8)),
                         PasteboardEntry(type: "public.html", data: Data("<b>bold</b>".utf8))],
                        [PasteboardEntry(type: "public.png", data: Data([0x89, 0x50]))]]

    func testPlainTextIsPastedAndEveryOriginalTypeComesBack() {
        let pasteboard = FakePasteboard(rich)
        var paste = PlainPaste()
        XCTAssertTrue(paste.press(pasteboard))
        XCTAssertEqual(pasteboard.items, [[PasteboardEntry(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("bold".utf8))]])
        XCTAssertTrue(paste.restore(pasteboard))
        XCTAssertEqual(pasteboard.items, rich, "every item and type, in order")
        XCTAssertNil(paste.pending, "nothing kept afterwards")
    }

    func testNothingIsRestoredWhenTheClipboardChangedInBetween() {
        let pasteboard = FakePasteboard(rich)
        var paste = PlainPaste()
        XCTAssertTrue(paste.press(pasteboard))
        pasteboard.externalWrite("copied meanwhile")
        XCTAssertFalse(paste.restore(pasteboard))
        XCTAssertEqual(pasteboard.plainText(), "copied meanwhile")
        XCTAssertNil(paste.pending)
    }

    func testNoTextMeansNoPasteAndNoChange() {
        let image = [[PasteboardEntry(type: "public.png", data: Data([1, 2, 3]))]]
        for items in [image, [], [[PasteboardEntry(type: NSPasteboard.PasteboardType.string.rawValue, data: Data())]]] {
            let pasteboard = FakePasteboard(items)
            var paste = PlainPaste()
            XCTAssertFalse(paste.press(pasteboard))
            XCTAssertEqual(pasteboard.changeCount, 0)
            XCTAssertEqual(pasteboard.items, items)
            XCTAssertFalse(paste.restore(pasteboard))
        }
    }

    func testASecondPressBeforeRestoreKeepsTheRealOriginal() {
        let pasteboard = FakePasteboard(rich)
        var paste = PlainPaste()
        XCTAssertTrue(paste.press(pasteboard))
        XCTAssertTrue(paste.press(pasteboard), "pastes again")
        XCTAssertEqual(pasteboard.replaced, 1, "the plain text is not saved as the original")
        XCTAssertTrue(paste.restore(pasteboard))
        XCTAssertEqual(pasteboard.items, rich)
    }

    func testAPressAfterAnotherAppCopiedStartsFresh() {
        let pasteboard = FakePasteboard(rich)
        var paste = PlainPaste()
        XCTAssertTrue(paste.press(pasteboard))
        pasteboard.externalWrite("new")
        XCTAssertTrue(paste.press(pasteboard))
        XCTAssertTrue(paste.restore(pasteboard))
        XCTAssertEqual(pasteboard.plainText(), "new")
    }

    /// The real NSPasteboard adapter against a private, uniquely named pasteboard: never the clipboard.
    func testSystemPasteboardAdapterRoundTripsOnAPrivatePasteboard() throws {
        let named = NSPasteboard(name: NSPasteboard.Name("ScrollSplitTests-\(UUID().uuidString)"))
        defer { named.releaseGlobally() }
        XCTAssertNotEqual(named.name, NSPasteboard.general.name)
        named.clearContents()
        let item = NSPasteboardItem()
        item.setString("{\\rtf1 hi}", forType: .rtf)
        item.setString("hi", forType: .string)
        named.writeObjects([item])
        let pasteboard = SystemPasteboard(named)
        let before = pasteboard.contents()
        var paste = PlainPaste()
        XCTAssertTrue(paste.press(pasteboard))
        XCTAssertEqual(named.types?.contains(.rtf), false, "formatting removed (AppKit may add its legacy string alias)")
        XCTAssertEqual(named.string(forType: .string), "hi")
        XCTAssertTrue(paste.restore(pasteboard))
        XCTAssertEqual(pasteboard.contents(), before)
        XCTAssertEqual(named.string(forType: .rtf), "{\\rtf1 hi}")
    }
}

// MARK: Microphone mute

private final class FakeDevice: InputDeviceControl {
    let id: UInt32
    let hasMute: Bool
    var muted = false
    var levels: [Float]?
    init(id: UInt32, hasMute: Bool, levels: [Float]? = nil) { self.id = id; self.hasMute = hasMute; self.levels = levels }
    var isMuted: Bool { muted }
    func setMuted(_ muted: Bool) { self.muted = muted }
    var volumes: [Float]? { levels }
    func setVolumes(_ volumes: [Float]) { levels = volumes }
}

final class MicrophoneMuteTests: XCTestCase {
    private func lookup(_ devices: FakeDevice...) -> (UInt32) -> InputDeviceControl? {
        { id in devices.first { $0.id == id } }
    }

    func testMutePropertyToggles() {
        let device = FakeDevice(id: 1, hasMute: true, levels: [0.7])
        var muter = MicrophoneMuter()
        XCTAssertTrue(muter.toggle(current: device, lookup: lookup(device)))
        XCTAssertTrue(device.muted)
        XCTAssertEqual(device.levels, [0.7], "volume untouched when a mute property exists")
        XCTAssertFalse(muter.toggle(current: device, lookup: lookup(device)))
        XCTAssertFalse(device.muted)
        XCTAssertFalse(muter.isHoldingMute)
    }

    func testVolumeFallbackRestoresEachChannelsLevel() {
        let device = FakeDevice(id: 2, hasMute: false, levels: [0.4, 0.6])
        var muter = MicrophoneMuter()
        XCTAssertTrue(muter.toggle(current: device, lookup: lookup(device)))
        XCTAssertEqual(device.levels, [0, 0])
        XCTAssertTrue(MicrophoneMuter.isMuted(device))
        XCTAssertFalse(muter.toggle(current: device, lookup: lookup(device)))
        XCTAssertEqual(device.levels, [0.4, 0.6])
    }

    func testANewDefaultDeviceIsMutedTooAndBothComeBack() {
        let builtIn = FakeDevice(id: 1, hasMute: true)
        let headset = FakeDevice(id: 2, hasMute: false, levels: [0.5])
        var muter = MicrophoneMuter()
        muter.toggle(current: builtIn, lookup: lookup(builtIn, headset))
        muter.defaultDeviceChanged(to: headset)
        XCTAssertEqual(headset.levels, [0], "plugging in a headset never unmutes the call")
        XCTAssertFalse(muter.toggle(current: headset, lookup: lookup(builtIn, headset)))
        XCTAssertFalse(builtIn.muted)
        XCTAssertEqual(headset.levels, [0.5])
    }

    func testADefaultDeviceChangeWhileUnmutedTouchesNothing() {
        let device = FakeDevice(id: 3, hasMute: true)
        var muter = MicrophoneMuter()
        muter.defaultDeviceChanged(to: device)
        XCTAssertFalse(device.muted)
    }

    func testUnmuteOnQuitRestoresEverythingAndSkipsDevicesThatAreGone() {
        let kept = FakeDevice(id: 1, hasMute: true)
        let unplugged = FakeDevice(id: 2, hasMute: false, levels: [0.3])
        var muter = MicrophoneMuter()
        muter.mute(kept)
        muter.mute(unplugged)
        muter.unmuteAll(lookup: lookup(kept))
        XCTAssertFalse(kept.muted)
        XCTAssertFalse(muter.isHoldingMute)
    }

    func testMutedElsewhereTheKeyUnmutesAndAnAlreadyMutedDeviceIsNotRecorded() {
        let device = FakeDevice(id: 4, hasMute: true)
        device.muted = true
        var muter = MicrophoneMuter()
        muter.mute(device)
        XCTAssertFalse(muter.isHoldingMute, "ScrollSplit did not mute it, so quitting will not unmute it")
        XCTAssertFalse(muter.toggle(current: device, lookup: lookup(device)))
        XCTAssertFalse(device.muted)
        let silent = FakeDevice(id: 5, hasMute: false, levels: [0])
        XCTAssertFalse(muter.toggle(current: silent, lookup: lookup(silent)))
        XCTAssertEqual(silent.levels, [1])
    }

    func testAMuteDoesNotRecordZeroAsTheLevelToRestore() {
        let device = FakeDevice(id: 6, hasMute: false, levels: [0.8])
        var muter = MicrophoneMuter()
        muter.mute(device)
        muter.defaultDeviceChanged(to: device) // the same device reported again
        muter.unmuteAll(lookup: lookup(device))
        XCTAssertEqual(device.levels, [0.8])
        XCTAssertFalse(muter.toggle(current: nil, lookup: lookup(device)), "no input device: nothing to mute")
    }

    func testARemuteAfterSomethingRaisedTheLevelStillRestoresTheOriginal() {
        let device = FakeDevice(id: 7, hasMute: false, levels: [0.8])
        var muter = MicrophoneMuter()
        muter.mute(device)
        device.levels = [0.2] // a call app nudged the level up
        muter.defaultDeviceChanged(to: device)
        XCTAssertEqual(device.levels, [0])
        muter.unmuteAll(lookup: lookup(device))
        XCTAssertEqual(device.levels, [0.8], "the level from before ScrollSplit muted")
    }
}

// MARK: Shortcuts and the bridge

final class ShortcutBridgeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "ScrollSplitTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func json(_ shortcut: KeyShortcut?) -> String {
        guard let shortcut else { return "null" }
        return "{\"keyCode\":\(shortcut.keyCode),\"carbonModifiers\":\(shortcut.carbonModifiers),\"keyEquivalent\":\"\(shortcut.keyEquivalent)\",\"keyLabel\":\"\(shortcut.keyLabel)\"}"
    }

    private let controlOptionV = KeyShortcut(keyCode: 9, carbonModifiers: KeyShortcut.control | KeyShortcut.option, keyEquivalent: "v", keyLabel: "V")
    private let hyperM = KeyShortcut(keyCode: 46, carbonModifiers: KeyShortcut.allowedModifiers, keyEquivalent: "m", keyLabel: "M")

    private func patch(_ text: String, current: [ShortcutCommand: KeyShortcut] = [:]) throws -> SettingsPatch {
        try SettingsPatch(data: Data(text.utf8), currentShortcuts: current)
    }

    func testCommandsAreListedInOrderAndStartUnassigned() throws {
        XCTAssertEqual(ShortcutCommand.allCases.map(\.rawValue), ["pastePlainText", "toggleMicrophoneMute"])
        XCTAssertEqual(ShortcutCommand.allCases.map(\.title), ["Paste as Plain Text", "Mute or Unmute Microphone"])
        let snapshot = ShortcutStore(defaults: defaults).snapshot
        XCTAssertEqual(snapshot.map { $0["command"] as? String }, ["pastePlainText", "toggleMicrophoneMute"])
        XCTAssertTrue(snapshot.allSatisfy { $0["shortcut"] is NSNull })
        let encoded = String(data: try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), encoding: .utf8)
        XCTAssertEqual(encoded, "[{\"command\":\"pastePlainText\",\"shortcut\":null,\"title\":\"Paste as Plain Text\"},{\"command\":\"toggleMicrophoneMute\",\"shortcut\":null,\"title\":\"Mute or Unmute Microphone\"}]")
    }

    func testAManagerPatchAssignsAndTheSnapshotCarriesTheSameShape() throws {
        // Exactly what the Mac Tools recorder sends: an empty title and the four fields.
        let value = try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"title\":\"\",\"shortcut\":\(json(controlOptionV))}]}")
        let store = ShortcutStore(defaults: defaults)
        value.shortcuts.apply(to: store)
        XCTAssertEqual(store.shortcut(for: .pastePlainText), controlOptionV)
        XCTAssertNil(store.shortcut(for: .toggleMicrophoneMute))
        let entry = try XCTUnwrap(store.snapshot.first)
        let shortcut = try XCTUnwrap(entry["shortcut"] as? [String: Any])
        XCTAssertEqual(Set(shortcut.keys), ["keyCode", "carbonModifiers", "keyEquivalent", "keyLabel"])
        XCTAssertEqual(shortcut["carbonModifiers"] as? UInt32, 0x1800)
        XCTAssertEqual(entry["title"] as? String, "Paste as Plain Text", "the title is always regenerated")
        XCTAssertEqual(controlOptionV.displayName, "⌃⌥V")

        try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":null}]}").shortcuts.apply(to: store)
        XCTAssertNil(store.shortcut(for: .pastePlainText), "null unassigns")
    }

    func testShortcutsNeedCommandControlOrOption() {
        let rejected: [UInt32] = [0, KeyShortcut.shift, 0x10000, KeyShortcut.command | 0x4000]
        for modifiers in rejected {
            let value = KeyShortcut(keyCode: 9, carbonModifiers: modifiers, keyEquivalent: "v", keyLabel: "V")
            XCTAssertThrowsError(try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":\(json(value))}]}"), "\(modifiers)")
        }
        for modifiers in [KeyShortcut.command, KeyShortcut.control | KeyShortcut.shift, KeyShortcut.option] {
            let value = KeyShortcut(keyCode: 9, carbonModifiers: modifiers, keyEquivalent: "v", keyLabel: "V")
            XCTAssertNoThrow(try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":\(json(value))}]}"), "\(modifiers)")
        }
    }

    func testMalformedShortcutsAreRejectedWhole() {
        let bad = [
            "{\"shortcuts\":{}}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\"}]}",
            "{\"shortcuts\":[{\"command\":\"unknown\",\"shortcut\":null}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":null,\"extra\":1}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":null},{\"command\":\"pastePlainText\",\"shortcut\":null}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"title\":3,\"shortcut\":null}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":9,\"carbonModifiers\":256,\"keyEquivalent\":\"v\"}}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":128,\"carbonModifiers\":256,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":9.5,\"carbonModifiers\":256,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":true,\"carbonModifiers\":256,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":9,\"carbonModifiers\":256,\"keyEquivalent\":\"\",\"keyLabel\":\"V\"}}]}",
            "{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":9,\"carbonModifiers\":256,\"keyEquivalent\":\"v\",\"keyLabel\":\" \"}}]}",
            "{\"enabled\":true,\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":{\"keyCode\":9,\"carbonModifiers\":512,\"keyEquivalent\":\"v\",\"keyLabel\":\"V\"}}]}",
            "{\"resetShortcuts\":1}",
            "{\"resetShortcuts\":true,\"shortcuts\":[]}"
        ]
        for text in bad { XCTAssertThrowsError(try patch(text), text) }
    }

    func testTheSameShortcutCannotGoToBothCommands() throws {
        XCTAssertThrowsError(try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":\(json(hyperM))},{\"command\":\"toggleMicrophoneMute\",\"shortcut\":\(json(hyperM))}]}"))
        // Against what is already assigned, too.
        XCTAssertThrowsError(try patch("{\"shortcuts\":[{\"command\":\"toggleMicrophoneMute\",\"shortcut\":\(json(hyperM))}]}", current: [.pastePlainText: hyperM]))
        // Only the key and modifiers count, not the labels.
        let relabelled = KeyShortcut(keyCode: hyperM.keyCode, carbonModifiers: hyperM.carbonModifiers, keyEquivalent: "x", keyLabel: "X")
        XCTAssertThrowsError(try patch("{\"shortcuts\":[{\"command\":\"toggleMicrophoneMute\",\"shortcut\":\(json(relabelled))}]}", current: [.pastePlainText: hyperM]))
        // Moving a shortcut from one command to the other in one patch is fine.
        XCTAssertNoThrow(try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":null},{\"command\":\"toggleMicrophoneMute\",\"shortcut\":\(json(hyperM))}]}", current: [.pastePlainText: hyperM]))
        // Reassigning the same command its own shortcut is no conflict.
        XCTAssertNoThrow(try patch("{\"shortcuts\":[{\"command\":\"pastePlainText\",\"shortcut\":\(json(hyperM))}]}", current: [.pastePlainText: hyperM]))
    }

    func testResetClearsBoth() throws {
        let store = ShortcutStore(defaults: defaults)
        store.set(controlOptionV, for: .pastePlainText)
        store.set(hyperM, for: .toggleMicrophoneMute)
        let value = try patch("{\"resetShortcuts\":true}", current: store.all)
        XCTAssertTrue(value.shortcuts.reset)
        XCTAssertTrue(value.values.isEmpty, "nothing written as a plain preference")
        value.shortcuts.apply(to: store)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertTrue(try patch("{\"resetShortcuts\":false}").shortcuts.isEmpty)
    }

    func testAStoredShortcutThatNoLongerValidatesReadsAsUnassigned() throws {
        defaults.set(try JSONEncoder().encode(KeyShortcut(keyCode: 9, carbonModifiers: KeyShortcut.shift, keyEquivalent: "v", keyLabel: "V")),
                     forKey: ShortcutStore.prefix + "pastePlainText")
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .pastePlainText))
    }
}

final class OverrideSettingsTests: XCTestCase {
    func testNewSwitchesDefaultOffAndAreBooleans() throws {
        let settings = ScrollSettings()
        XCTAssertFalse(settings.holdToQuit)
        XCTAssertFalse(settings.capsLockIsHyper)
        XCTAssertFalse(settings.capsLockTapIsEscape)
        XCTAssertFalse(settings.needsKeyTap)
        for key in ["holdToQuit", "capsLockIsHyper", "capsLockTapIsEscape"] {
            XCTAssertTrue(SettingsPatch.booleanKeys.contains(key))
            XCTAssertThrowsError(try SettingsPatch(data: Data("{\"\(key)\":1}".utf8)), key)
            XCTAssertThrowsError(try SettingsPatch(data: Data("{\"\(key)\":null}".utf8)), key)
            let patch = try SettingsPatch(data: Data("{\"\(key)\":true}".utf8))
            XCTAssertEqual(patch.values[key] as? Bool, true)
        }
    }

    func testTheKeyTapIsNeededOnlyWhileOnAndAFeatureWantsIt() {
        var settings = ScrollSettings()
        settings.holdToQuit = true
        XCTAssertFalse(settings.needsKeyTap, "the master switch is off")
        settings.enabled = true
        XCTAssertTrue(settings.needsKeyTap)
        settings.holdToQuit = false
        settings.capsLockTapIsEscape = true
        XCTAssertFalse(settings.needsKeyTap, "Escape on tap alone needs Caps Lock as Hyper")
        settings.capsLockIsHyper = true
        XCTAssertTrue(settings.needsKeyTap)
    }

    func testCapsLockRemapAvailabilityIsReadOnlyAndGatesTheSwitch() throws {
        XCTAssertThrowsError(try SettingsPatch(data: Data("{\"capsLockRemapAvailable\":true}".utf8)))
        XCTAssertThrowsError(try SettingsPatch(data: Data("{\"capsLockIsHyper\":true,\"enabled\":true}".utf8), capsLockRemapAvailable: false))
        XCTAssertNoThrow(try SettingsPatch(data: Data("{\"capsLockIsHyper\":false}".utf8), capsLockRemapAvailable: false))
        XCTAssertNoThrow(try SettingsPatch(data: Data("{\"capsLockTapIsEscape\":true}".utf8), capsLockRemapAvailable: false))
    }

    func testAnOlderManagersPatchStillValidates() throws {
        let old = "{\"enabled\":true,\"reverseVertical\":false,\"reverseHorizontal\":true,\"speedMultiplier\":1.5,\"launchAtLogin\":false,\"smoothScrolling\":true,\"sideButtonsNavigate\":true,\"mouseAccelerationOff\":false}"
        let patch = try SettingsPatch(data: Data(old.utf8), capsLockRemapAvailable: false)
        XCTAssertEqual(patch.values.count, 8)
        XCTAssertTrue(patch.shortcuts.isEmpty)
    }
}

// MARK: Panel render

/// Renders the hold-to-quit panel offscreen. With SCROLLSPLIT_PANEL_SNAPSHOT=/dir/name.png
/// it also writes name-light.png and name-dark.png beside it.
final class HoldToQuitRenderTests: XCTestCase {
    func testRendersInBothAppearances() throws {
        _ = NSApplication.shared
        let path = ProcessInfo.processInfo.environment["SCROLLSPLIT_PANEL_SNAPSHOT"]
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let model = HoldToQuitModel(icon: icon, appName: "TextEdit", progress: 0.62)
            let hosting = NSHostingView(rootView: HoldToQuitView(model: model))
            hosting.appearance = NSAppearance(named: appearance)
            let size = hosting.fittingSize
            XCTAssertGreaterThanOrEqual(size.width, 240, mode)
            XCTAssertLessThanOrEqual(size.width, 360, mode)
            guard let path else { continue }
            // A backdrop behind the panel, as on a real desktop, so the material reads.
            let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 80, height: size.height + 80))
            backdrop.wantsLayer = true
            backdrop.appearance = NSAppearance(named: appearance)
            backdrop.layer?.backgroundColor = (mode == "light" ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
            hosting.frame = NSRect(x: 40, y: 40, width: size.width, height: size.height)
            backdrop.addSubview(hosting)
            let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = backdrop
            defer { window.contentView = nil }
            backdrop.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(base)-\(mode).png"))
        }
    }
}
