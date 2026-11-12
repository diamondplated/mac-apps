import XCTest
@testable import MixBarCore

final class GroupingTests: XCTestCase {
    let chrome = RunningApp(pid: 100, bundleIdentifier: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
    let helperApp = RunningApp(pid: 101, bundleIdentifier: "com.google.Chrome.helper", name: "Google Chrome Helper",
                               bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app")
    let music = RunningApp(pid: 200, bundleIdentifier: "com.apple.Music", name: "Music", bundlePath: "/System/Applications/Music.app")
    let mixBar = RunningApp(pid: 300, bundleIdentifier: "com.andrew.mixbar", name: "MixBar", bundlePath: "/Applications/MixBar.app")

    func group(_ processes: [AudioProcess], apps: [RunningApp]? = nil) -> [AppGroup] {
        AppGrouping.group(processes, apps: apps ?? [chrome, helperApp, music, mixBar], excludingPID: 300, excludingBundleIdentifier: "com.andrew.mixbar")
    }

    func testHelperProcessesGroupUnderTheirApp() {
        let groups = group([
            AudioProcess(objectID: 1, pid: 100, bundleIdentifier: "com.google.Chrome", isRunningOutput: false),
            AudioProcess(objectID: 2, pid: 101, bundleIdentifier: "com.google.Chrome.helper", isRunningOutput: true),
            AudioProcess(objectID: 3, pid: 102, bundleIdentifier: "com.google.Chrome.helper.renderer", isRunningOutput: false),
            AudioProcess(objectID: 4, pid: 200, bundleIdentifier: "com.apple.Music", isRunningOutput: false)
        ])
        XCTAssertEqual(groups.map(\.bundleIdentifier), ["com.google.Chrome", "com.apple.Music"])
        XCTAssertEqual(groups[0].processObjectIDs, [1, 2, 3], "one slider moves every Chrome process")
        XCTAssertTrue(groups[0].isPlaying, "playing when any helper plays")
        XCTAssertEqual(groups[0].name, "Google Chrome")
        XCTAssertFalse(groups[1].isPlaying)
    }

    func testProcessInsideAnAppBundleBelongsToThatApp() {
        let groups = group([AudioProcess(objectID: 7, pid: 555, bundleIdentifier: "org.example.unrelated",
                                         executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Thing/audio-service", isRunningOutput: true)])
        XCTAssertEqual(groups.map(\.bundleIdentifier), ["com.google.Chrome"])
    }

    func testMixBarAndUnnamedProcessesAreNeverGrouped() {
        let groups = group([
            AudioProcess(objectID: 1, pid: 300, bundleIdentifier: "com.andrew.mixbar", isRunningOutput: true),
            AudioProcess(objectID: 2, pid: 301, bundleIdentifier: "com.andrew.mixbar.helper", isRunningOutput: true),
            AudioProcess(objectID: 3, pid: 400, bundleIdentifier: nil, isRunningOutput: true),
            AudioProcess(objectID: 4, pid: 401, bundleIdentifier: "bad id with spaces", isRunningOutput: true)
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testBackgroundProcessIsItsOwnApp() {
        let groups = group([AudioProcess(objectID: 9, pid: 900, bundleIdentifier: "com.example.daemon", executablePath: "/usr/local/bin/sound-daemon", isRunningOutput: true)])
        XCTAssertEqual(groups.first?.bundleIdentifier, "com.example.daemon")
        XCTAssertEqual(groups.first?.name, "sound-daemon")
    }

    func testMixerRowsArePlayingAppsPlusRunningAppsWithASetting() {
        let snapshot = AudioSnapshot(groups: [
            AppGroup(bundleIdentifier: "com.spotify.client", name: "Spotify", processObjectIDs: [1], isPlaying: true),
            AppGroup(bundleIdentifier: "com.apple.Safari", name: "Safari", processObjectIDs: [2], isPlaying: false),
            AppGroup(bundleIdentifier: "us.zoom.xos", name: "zoom.us", processObjectIDs: [3], isPlaying: false)
        ], outputs: [], defaultOutputUID: nil)
        let saved = ["com.apple.Music": AppVolume(bundleIdentifier: "com.apple.Music", name: "Music", volume: 0.4)]
        let rows = MixerEditing.rows(snapshot: snapshot, liveBundles: ["us.zoom.xos"], runningApps: [music, chrome], setting: { saved[$0] })
        XCTAssertEqual(rows.map(\.name), ["Music", "Spotify", "zoom.us"], "sorted by name; Safari is silent, Chrome has no setting")
        XCTAssertEqual(rows[0].setting.volume, 0.4)
        XCTAssertEqual(rows[1].setting, AppVolume(bundleIdentifier: "com.spotify.client", name: "Spotify"))
    }

    func testEditingRemovesNeutralEntriesAndCapsTheList() {
        var list = MixerEditing.updating([], with: AppVolume(bundleIdentifier: "a.b", name: "A", volume: 0.5))
        XCTAssertEqual(list.count, 1)
        list = MixerEditing.updating(list, with: AppVolume(bundleIdentifier: "a.b", name: "A", volume: 1))
        XCTAssertTrue(list.isEmpty, "back to default: forgotten")
        XCTAssertTrue(MixerEditing.updating([], with: AppVolume(bundleIdentifier: "a.b", name: "A")).isEmpty)
        let full = (0..<100).map { AppVolume(bundleIdentifier: "app.n\($0)", name: "", volume: 0.5) }
        XCTAssertEqual(MixerEditing.updating(full, with: AppVolume(bundleIdentifier: "one.more", name: "", volume: 0.5)).count, 100)
        let pruned = MixerEditing.pruneSession(["a.b": AppVolume(bundleIdentifier: "a.b", name: "A", volume: 0.5)], runningBundleIdentifiers: [])
        XCTAssertTrue(pruned.isEmpty, "a session choice ends when the app quits")
    }

    func testDetent() {
        XCTAssertEqual(VolumeDetent.snap(0.97), 1)
        XCTAssertEqual(VolumeDetent.snap(1.03), 1)
        XCTAssertEqual(VolumeDetent.snap(1.05), 1.05)
        XCTAssertEqual(VolumeDetent.snap(-1), 0)
        XCTAssertEqual(VolumeDetent.snap(3), 2)
        XCTAssertEqual(VolumeDetent.percent(1.5), "150%")
    }
}
