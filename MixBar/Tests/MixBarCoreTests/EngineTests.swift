import XCTest
@testable import MixBarCore

/// Records every call; never touches Core Audio.
final class FakeAudio: AudioService {
    var tapsAvailable = true
    var created: [TapSpec] = []
    var destroyed: [TapHandle] = []
    var gains: [TapHandle: Float] = [:]
    var health: [TapHandle: TapHealth] = [:]
    /// Errors to throw from the next createTap calls, in order.
    var failures: [TapError] = []
    private var next: UInt64 = 1
    private(set) var alive = Set<TapHandle>()

    func createTap(_ spec: TapSpec, gain: Float) throws -> TapHandle {
        if !failures.isEmpty { throw failures.removeFirst() }
        created.append(spec)
        let handle = TapHandle(next); next += 1
        gains[handle] = gain
        alive.insert(handle)
        return handle
    }
    func destroyTap(_ handle: TapHandle) { destroyed.append(handle); alive.remove(handle) }
    func setGain(_ gain: Float, for handle: TapHandle) { gains[handle] = gain }
    func health(of handle: TapHandle) -> TapHealth { health[handle] ?? TapHealth(framesRendered: 0, sawSignal: false) }
}

final class EngineTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let speakers = OutputDevice(uid: "speakers", name: "MacBook Pro Speakers")
    let headphones = OutputDevice(uid: "usb-headphones", name: "USB Headphones")

    func snapshot(playing: Bool = true, processes: [UInt32] = [10, 11], defaultUID: String? = "speakers", outputs: [OutputDevice]? = nil, extra: [AppGroup] = []) -> AudioSnapshot {
        AudioSnapshot(groups: [AppGroup(bundleIdentifier: "com.apple.Music", name: "Music", processObjectIDs: processes, isPlaying: playing)] + extra,
                      outputs: outputs ?? [speakers, headphones], defaultOutputUID: defaultUID)
    }

    func music(_ volume: Double = 1, muted: Bool = false, output: String? = nil) -> AppVolume {
        AppVolume(bundleIdentifier: "com.apple.Music", name: "Music", volume: volume, muted: muted, outputDeviceUID: output)
    }

    // MARK: Which apps get a tap

    func testEveryCombinationOfVolumeMuteAndOutput() {
        let group = snapshot().groups[0]
        for volume in [0.0, 0.5, 1.0, 1.5, 2.0] {
            for muted in [false, true] {
                for output in [nil, "usb-headphones", "unplugged-device"] as [String?] {
                    let spec = TapPlanner.spec(for: group, setting: music(volume, muted: muted, output: output), outputs: [speakers, headphones], defaultOutputUID: "speakers")
                    let pinned = output == "usb-headphones"
                    let wants = volume != 1 || muted || pinned
                    XCTAssertEqual(spec != nil, wants, "volume \(volume) muted \(muted) output \(output ?? "default")")
                    if let spec {
                        XCTAssertEqual(spec.outputDeviceUID, pinned ? "usb-headphones" : "speakers", "a missing output falls back to the system output")
                        XCTAssertEqual(spec.processObjectIDs, [10, 11])
                    }
                }
            }
        }
        XCTAssertNil(TapPlanner.spec(for: group, setting: nil, outputs: [speakers], defaultOutputUID: "speakers"), "no setting, no tap")
        XCTAssertNil(TapPlanner.spec(for: group, setting: music(0.5), outputs: [], defaultOutputUID: nil), "no output device, no tap")
        let silent = AppGroup(bundleIdentifier: "com.apple.Music", name: "Music", processObjectIDs: [], isPlaying: false)
        XCTAssertNil(TapPlanner.spec(for: silent, setting: music(0.5), outputs: [speakers], defaultOutputUID: "speakers"), "no process, no tap")
    }

    func testNeutralAppIsNeverTapped() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music() }, now: t0)
        engine.reconcile(snapshot(), settings: { _ in nil }, now: t0)
        XCTAssertTrue(audio.created.isEmpty)
        XCTAssertTrue(engine.live.isEmpty)
    }

    func testTapIsCreatedOnceAndGainChangesDoNotRebuild() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        var setting = music(0.5)
        for second in 0..<5 { engine.reconcile(snapshot(), settings: { _ in setting }, now: t0 + Double(second)) }
        XCTAssertEqual(audio.created.count, 1)
        let handle = engine.live["com.apple.Music"]!.handle
        XCTAssertEqual(audio.gains[handle], 0.5)
        setting.volume = 1.5
        engine.updateGains { _ in setting }
        XCTAssertEqual(audio.gains[handle], 1.5)
        setting.muted = true
        engine.reconcile(snapshot(), settings: { _ in setting }, now: t0 + 6)
        XCTAssertEqual(audio.gains[handle], 0, "mute is gain zero on the same tap")
        XCTAssertEqual(audio.created.count, 1)
        XCTAssertTrue(audio.destroyed.isEmpty)
    }

    func testReturningToDefaultRemovesTheTapExactlyThen() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        var setting = music(0.5, muted: true, output: "usb-headphones")
        engine.reconcile(snapshot(), settings: { _ in setting }, now: t0)
        setting.volume = 1
        engine.reconcile(snapshot(), settings: { _ in setting }, now: t0 + 1)
        setting.muted = false
        engine.reconcile(snapshot(), settings: { _ in setting }, now: t0 + 2)
        XCTAssertEqual(audio.created.count, 1, "still muted and pinned: same tap")
        XCTAssertTrue(audio.destroyed.isEmpty)
        setting.outputDeviceUID = nil
        engine.reconcile(snapshot(), settings: { _ in setting }, now: t0 + 3)
        XCTAssertEqual(audio.destroyed.count, 1)
        XCTAssertTrue(engine.live.isEmpty)
        XCTAssertTrue(audio.alive.isEmpty)
    }

    func testTapWaitsForSoundAndEndsWhenTheAppStops() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(playing: false), settings: { _ in self.music(0.5) }, now: t0)
        XCTAssertTrue(audio.created.isEmpty, "not playing yet")
        engine.reconcile(snapshot(playing: true), settings: { _ in self.music(0.5) }, now: t0 + 1)
        XCTAssertEqual(audio.created.count, 1)
        engine.reconcile(snapshot(playing: false), settings: { _ in self.music(0.5) }, now: t0 + 5)
        XCTAssertEqual(engine.live.count, 1, "a short pause keeps the tap")
        engine.reconcile(snapshot(playing: true), settings: { _ in self.music(0.5) }, now: t0 + 8)
        engine.reconcile(snapshot(playing: false), settings: { _ in self.music(0.5) }, now: t0 + 8 + MixerEngine.idleGrace)
        XCTAssertTrue(engine.live.isEmpty, "silent for the whole grace period")
        XCTAssertEqual(audio.created.count, 1)
        XCTAssertEqual(audio.destroyed.count, 1)
        let quit = AudioSnapshot(groups: [], outputs: [speakers], defaultOutputUID: "speakers")
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0 + 30)
        engine.reconcile(quit, settings: { _ in self.music(0.5) }, now: t0 + 31)
        XCTAssertTrue(engine.live.isEmpty, "the app quit")
        XCTAssertTrue(audio.alive.isEmpty)
    }

    func testNewHelperProcessOrNewOutputRebuildsTheTap() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(processes: [10]), settings: { _ in self.music(0.5) }, now: t0)
        engine.reconcile(snapshot(processes: [10, 12]), settings: { _ in self.music(0.5) }, now: t0 + 1)
        XCTAssertEqual(audio.created.map(\.processObjectIDs), [[10], [10, 12]])
        engine.reconcile(snapshot(processes: [10, 12], defaultUID: "usb-headphones"), settings: { _ in self.music(0.5) }, now: t0 + 2)
        XCTAssertEqual(audio.created.last?.outputDeviceUID, "usb-headphones", "System Default follows the default output")
        XCTAssertEqual(audio.destroyed.count, 2)
        XCTAssertEqual(audio.alive.count, 1)
    }

    func testUnavailableSystemNeverTaps() {
        let audio = FakeAudio()
        audio.tapsAvailable = false
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.2) }, now: t0)
        XCTAssertTrue(audio.created.isEmpty)
    }

    func testSettingsAreReappliedOnlyWhenRememberingIsOn() {
        var settings = MixBarSettings()
        settings.appVolumes = [music(0.3)]
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { SettingResolver.effective($0, settings: settings, session: [:]) }, now: t0)
        XCTAssertEqual(audio.created.count, 1, "remembered: reapplied when Music plays")
        settings.remembersVolumes = false
        let other = MixerEngine(service: FakeAudio())
        other.reconcile(snapshot(), settings: { SettingResolver.effective($0, settings: settings, session: [:]) }, now: t0)
        XCTAssertTrue(other.live.isEmpty, "not remembered: the saved setting is ignored")
        XCTAssertEqual(SettingResolver.effective("com.apple.Music", settings: settings, session: ["com.apple.Music": music(0.7)])?.volume, 0.7,
                       "a choice made in the mixer still applies while the app runs")
    }

    // MARK: Failure paths: every one ends rebuilt or with no tap

    func testCreateFailureLeavesNoTapAndIsNotRetriedUntilSomethingChanges() {
        let audio = FakeAudio()
        audio.failures = [.failed(-50)]
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        XCTAssertTrue(engine.live.isEmpty)
        XCTAssertNotNil(engine.failed["com.apple.Music"])
        engine.reconcile(snapshot(), settings: { _ in self.music(0.6) }, now: t0 + 1)
        XCTAssertTrue(audio.created.isEmpty, "same spec: not retried every second")
        engine.clearFailures()
        engine.reconcile(snapshot(), settings: { _ in self.music(0.6) }, now: t0 + 2)
        XCTAssertEqual(audio.created.count, 1, "retried when the mixer opens")
    }

    func testBrokenTapIsRebuiltOnceThenRemoved() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        engine.tapFailed("com.apple.Music", now: t0 + 1)
        XCTAssertEqual(audio.created.count, 2, "rebuilt")
        XCTAssertEqual(audio.alive.count, 1)
        engine.tapFailed("com.apple.Music", now: t0 + 2)
        XCTAssertTrue(engine.live.isEmpty, "broke again: removed")
        XCTAssertTrue(audio.alive.isEmpty)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0 + 3)
        XCTAssertTrue(engine.live.isEmpty, "and not recreated in a loop")
    }

    func testFailedRebuildLeavesNoTap() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        audio.failures = [.failed(-1)]
        engine.tapFailed("com.apple.Music", now: t0 + 1)
        XCTAssertTrue(engine.live.isEmpty)
        XCTAssertTrue(audio.alive.isEmpty)
    }

    func testUnpluggedOutputFallsBackToTheSystemOutput() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        let pinned = music(0.5, output: "usb-headphones")
        engine.reconcile(snapshot(), settings: { _ in pinned }, now: t0)
        // Unplugging breaks the chain and removes the device from the list.
        engine.tapFailed("com.apple.Music", now: t0 + 1)
        engine.reconcile(snapshot(outputs: [speakers]), settings: { _ in pinned }, now: t0 + 1)
        XCTAssertEqual(engine.live["com.apple.Music"]?.spec.outputDeviceUID, "speakers")
        XCTAssertEqual(audio.alive.count, 1)
        // A neutral volume pinned to an unplugged output needs no tap at all.
        engine.reconcile(snapshot(outputs: [speakers]), settings: { _ in self.music(1, output: "usb-headphones") }, now: t0 + 2)
        XCTAssertTrue(audio.alive.isEmpty)
    }

    func testStalledIOIsRebuilt() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio, captureStatus: .granted)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        let first = engine.live["com.apple.Music"]!.handle
        audio.health[first] = TapHealth(framesRendered: 512, sawSignal: true)
        engine.checkHealth(snapshot(), now: t0 + 1)
        engine.checkHealth(snapshot(), now: t0 + 2)
        XCTAssertEqual(engine.live["com.apple.Music"]?.handle, first, "one quiet second is fine")
        engine.checkHealth(snapshot(), now: t0 + 1 + MixerEngine.stallTimeout)
        XCTAssertNotEqual(engine.live["com.apple.Music"]?.handle, first, "stalled: rebuilt")
        XCTAssertEqual(audio.alive.count, 1)
    }

    func testFirstSoundGrantsCapture() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        var reported: [CaptureStatus] = []
        engine.onCaptureStatusChange = { reported.append($0) }
        XCTAssertEqual(engine.captureStatus, .unknown)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        audio.health[engine.live["com.apple.Music"]!.handle] = TapHealth(framesRendered: 512, sawSignal: true)
        engine.checkHealth(snapshot(), now: t0 + 1)
        XCTAssertEqual(engine.captureStatus, .granted)
        XCTAssertEqual(reported, [.granted])
    }

    func testSilentFirstTapMeansCaptureWasRefusedAndEveryTapGoes() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        let two = snapshot(extra: [AppGroup(bundleIdentifier: "com.spotify.client", name: "Spotify", processObjectIDs: [20], isPlaying: true)])
        engine.reconcile(two, settings: { AppVolume(bundleIdentifier: $0, name: $0, volume: 0.5) }, now: t0)
        XCTAssertEqual(engine.live.count, 2)
        var frames: UInt64 = 0
        for second in 1...Int(MixerEngine.permissionTimeout) {
            frames += 480
            for tap in engine.live.values { audio.health[tap.handle] = TapHealth(framesRendered: frames, sawSignal: false) }
            engine.checkHealth(two, now: t0 + Double(second))
        }
        XCTAssertEqual(engine.captureStatus, .denied)
        XCTAssertTrue(engine.live.isEmpty, "no app left muted with nothing replaying it")
        XCTAssertTrue(audio.alive.isEmpty)
    }

    func testSilenceFromAPausedAppIsNotARefusal() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        let handle = engine.live["com.apple.Music"]!.handle
        for second in 1...6 {
            audio.health[handle] = TapHealth(framesRendered: UInt64(second * 480), sawSignal: false)
            engine.checkHealth(snapshot(playing: false), now: t0 + Double(second))
        }
        XCTAssertEqual(engine.captureStatus, .unknown)
        XCTAssertEqual(engine.live.count, 1)
    }

    func testPermissionErrorFromCreateMeansDenied() {
        let audio = FakeAudio()
        audio.failures = [.permissionDenied]
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        XCTAssertEqual(engine.captureStatus, .denied)
        XCTAssertTrue(engine.live.isEmpty)
    }

    func testRebuildAllAndRemoveAll() {
        let audio = FakeAudio()
        let engine = MixerEngine(service: audio)
        engine.reconcile(snapshot(), settings: { _ in self.music(0.5) }, now: t0)
        engine.rebuildAll(snapshot(), settings: { _ in self.music(0.5) }, now: t0 + 1)
        XCTAssertEqual(audio.created.count, 2)
        XCTAssertEqual(audio.alive.count, 1)
        engine.removeAll()
        XCTAssertTrue(audio.alive.isEmpty)
        XCTAssertTrue(engine.live.isEmpty)
    }
}
