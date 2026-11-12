import XCTest
@testable import StayLitCore

final class KeyRoutingTests: XCTestCase {
    let builtIn = DisplayInfo(id: 1, name: "Built-in Retina Display", isBuiltin: true, vendor: 0x0610)
    let studio = DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, vendor: DisplayInfo.appleVendor,
                             brightness: DDC.Value(current: 50, maximum: 100), volume: DDC.Value(current: 50, maximum: 100))
    let dell = DisplayInfo(id: 3, name: "DELL U2723QE", isBuiltin: false, vendor: 0x10AC,
                           brightness: DDC.Value(current: 70, maximum: 100), volume: DDC.Value(current: 30, maximum: 100))
    let silent = DisplayInfo(id: 4, name: "Old Monitor", isBuiltin: false, vendor: 0x1234)
    var displays: [DisplayInfo] { [builtIn, studio, dell, silent] }

    func testDecodesSystemDefinedMediaKeys() {
        func data1(_ type: Int, _ state: Int, repeating: Bool = false) -> Int { type << 16 | state << 8 | (repeating ? 1 : 0) }
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: data1(2, 0x0A)), MediaKeyEvent(key: .brightnessUp, isDown: true, isRepeat: false))
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: data1(3, 0x0B)), MediaKeyEvent(key: .brightnessDown, isDown: false, isRepeat: false))
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: data1(0, 0x0A, repeating: true)), MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: true))
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: data1(1, 0x0A))?.key, .volumeDown)
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: data1(7, 0x0A))?.key, .mute)
        XCTAssertNil(MediaKeyEvent(subtype: 8, data1: data1(16, 0x0A)), "play/pause is not ours")
        XCTAssertNil(MediaKeyEvent(subtype: 8, data1: data1(21, 0x0A)), "keyboard backlight is not ours")
        XCTAssertNil(MediaKeyEvent(subtype: 7, data1: data1(2, 0x0A)), "other system-defined subtypes pass")
        XCTAssertNil(MediaKeyEvent(subtype: 8, data1: data1(2, 0x00)))
    }

    func testBrightnessClaimedOnlyOnAControllableExternalUnderThePointer() {
        let cases: [(DisplayInfo?, Bool, KeyClaim)] = [
            (dell, true, .brightness(display: 3, up: true)),
            (dell, false, .pass),
            (builtIn, true, .pass),
            (studio, true, .pass),
            (silent, true, .pass),
            (nil, true, .pass)
        ]
        for (pointer, on, expected) in cases {
            for volumeOn in [false, true] {
                XCTAssertEqual(KeyRouter.decide(.brightnessUp, pointerDisplay: pointer, volumeDisplay: 3, displays: displays,
                                                brightnessOn: on, volumeOn: volumeOn), expected, "\(pointer?.name ?? "none") on=\(on)")
            }
        }
        XCTAssertEqual(KeyRouter.decide(.brightnessDown, pointerDisplay: dell, volumeDisplay: nil, displays: displays,
                                        brightnessOn: true, volumeOn: false), .brightness(display: 3, up: false))
    }

    func testVolumeClaimedOnlyForADisplayOutputWithoutSystemVolume() {
        for key in [MediaKey.volumeUp, .volumeDown, .mute] {
            let expected: KeyClaim = key == .mute ? .mute(display: 3) : .volume(display: 3, up: key == .volumeUp)
            for pointer in [builtIn, dell, silent] {
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: 3, displays: displays, brightnessOn: false, volumeOn: true), expected,
                               "volume follows the sound output, not the pointer")
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: 3, displays: displays, brightnessOn: true, volumeOn: false), .pass)
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: nil, displays: displays, brightnessOn: true, volumeOn: true), .pass)
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: 4, displays: displays, brightnessOn: true, volumeOn: true), .pass,
                               "a display that does not answer volume reads")
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: 2, displays: displays, brightnessOn: true, volumeOn: true), .pass,
                               "an Apple display has system volume")
                XCTAssertEqual(KeyRouter.decide(key, pointerDisplay: pointer, volumeDisplay: 9, displays: displays, brightnessOn: true, volumeOn: true), .pass,
                               "a display that went away")
            }
        }
        XCTAssertFalse(KeyClaim.pass.claimsEvent)
        XCTAssertTrue(KeyClaim.mute(display: 3).claimsEvent)
    }

    func testVolumeTargetFromOutputDevice() {
        let hdmi = AudioOutput(name: "DELL U2723QE", isDisplayTransport: true, hasSystemVolume: false)
        XCTAssertEqual(VolumeTarget.resolve(output: hdmi, displays: displays), 3)
        XCTAssertNil(VolumeTarget.resolve(output: AudioOutput(name: "DELL U2723QE", isDisplayTransport: true, hasSystemVolume: true), displays: displays),
                     "macOS already controls this output")
        XCTAssertNil(VolumeTarget.resolve(output: AudioOutput(name: "MacBook Pro Speakers", isDisplayTransport: false, hasSystemVolume: false), displays: displays))
        XCTAssertNil(VolumeTarget.resolve(output: nil, displays: displays))
        // An unmatched name falls back to the only external display with volume.
        XCTAssertEqual(VolumeTarget.resolve(output: AudioOutput(name: "HDMI", isDisplayTransport: true, hasSystemVolume: false), displays: displays), 3)
        let second = DisplayInfo(id: 5, name: "LG HDR 4K", isBuiltin: false, vendor: 0x1E6D, volume: DDC.Value(current: 10, maximum: 100))
        XCTAssertNil(VolumeTarget.resolve(output: AudioOutput(name: "HDMI", isDisplayTransport: true, hasSystemVolume: false), displays: displays + [second]),
                     "two candidates and no name match: leave the keys alone")
        XCTAssertEqual(VolumeTarget.resolve(output: AudioOutput(name: "LG HDR 4K", isDisplayTransport: true, hasSystemVolume: false), displays: displays + [second]), 5)
    }

    func testDisplayControllability() {
        XCTAssertFalse(builtIn.controllable)
        XCTAssertFalse(studio.controllable, "Apple displays are left to macOS")
        XCTAssertTrue(dell.controllable)
        XCTAssertFalse(silent.controllable)
    }

    func testChannelMatching() {
        let a = ChannelAttributes(vendor: 0x10AC, product: 0xA0C4, serial: 111)
        let b = ChannelAttributes(vendor: 0x10AC, product: 0xA0C4, serial: 222)
        let lg = ChannelAttributes(vendor: 0x1E6D, product: 0x5B10, serial: 0)
        let displays: [(id: UInt32, attributes: ChannelAttributes)] = [(7, b), (8, a), (9, ChannelAttributes(vendor: 0x1E6D, product: 0x5B10, serial: 555))]
        XCTAssertEqual(ChannelMatcher.match(channels: [a, b, lg], displays: displays), [0: 8, 1: 7, 2: 9], "serials pick between identical models")
        XCTAssertEqual(ChannelMatcher.match(channels: [ChannelAttributes(vendor: 1, product: 2, serial: 3)], displays: displays), [:])
        XCTAssertEqual(ChannelMatcher.match(channels: [nil], displays: [(4, a)]), [0: 4], "one channel, one display")
        XCTAssertEqual(ChannelMatcher.match(channels: [nil, nil], displays: [(4, a), (5, b)]), [:], "never guess between two")
        let twins = ChannelAttributes(vendor: 1, product: 2, serial: 0)
        XCTAssertEqual(ChannelMatcher.match(channels: [twins, twins], displays: [(4, twins), (5, twins)]), [0: 4, 1: 5])
    }

    func testGatePassesEverythingUnlessWantedAndClaimed() {
        let down = MediaKeyEvent(key: .brightnessUp, isDown: true, isRepeat: false)
        let held = MediaKeyEvent(key: .brightnessUp, isDown: true, isRepeat: true)
        let up = MediaKeyEvent(key: .brightnessUp, isDown: false, isRepeat: false)
        let claim: (MediaKey) -> KeyClaim = { _ in .brightness(display: 3, up: true) }
        var gate = MediaKeyGate()
        XCTAssertEqual(gate.handle(down, wanted: false, claim: claim), .pass, "switched off: untouched")
        XCTAssertEqual(gate.handle(nil, wanted: true, claim: claim), .pass, "not a media key we handle")
        XCTAssertEqual(gate.handle(down, wanted: true, claim: { _ in .pass }), .pass, "unclaimed down")
        XCTAssertEqual(gate.handle(up, wanted: true, claim: claim), .pass, "an up whose down passed also passes")
        XCTAssertEqual(gate.handle(down, wanted: true, claim: claim), .act(.brightness(display: 3, up: true)))
        XCTAssertEqual(gate.handle(held, wanted: true, claim: claim), .act(.brightness(display: 3, up: true)), "repeats act")
        XCTAssertEqual(gate.handle(up, wanted: true, claim: { _ in .pass }), .swallow, "an up follows its claimed down even if routing changed")
        XCTAssertEqual(gate.handle(up, wanted: true, claim: claim), .pass, "only once")
        // A claimed down, then the pointer moves to the built-in display before the up.
        XCTAssertEqual(gate.handle(down, wanted: true, claim: claim), .act(.brightness(display: 3, up: true)))
        XCTAssertEqual(gate.handle(down, wanted: true, claim: { _ in .pass }), .pass)
        XCTAssertEqual(gate.handle(up, wanted: true, claim: claim), .pass, "the last down passed, so its up passes")
        // Switching off forgets claimed downs.
        _ = gate.handle(down, wanted: true, claim: claim)
        XCTAssertEqual(gate.handle(up, wanted: false, claim: claim), .pass)
        XCTAssertTrue(gate.claimedDowns.isEmpty)
    }
}
