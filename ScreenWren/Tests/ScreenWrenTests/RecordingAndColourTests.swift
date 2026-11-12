import AppKit
import ScreenCaptureKit
import XCTest

@testable import ScreenWren

final class RecordingAndColourTests: XCTestCase {
    // MARK: Pick Colour

    func testHexIsSRGBAndConvertsDisplayP3() {
        XCTAssertEqual(hexString(for: NSColor(srgbRed: 58 / 255, green: 123 / 255, blue: 213 / 255, alpha: 1)), "#3A7BD5")
        XCTAssertEqual(hexString(for: .black), "#000000")
        XCTAssertEqual(hexString(for: NSColor(white: 1, alpha: 1)), "#FFFFFF")
        // ColorSync's Display P3 → sRGB. Formatting the P3 components directly would give #CC4D33.
        let p3 = NSColor(displayP3Red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        XCTAssertEqual(hexString(for: p3), "#DD4025")
        XCTAssertNotEqual(hexString(for: p3), "#CC4D33")
        XCTAssertEqual(hexString(for: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)), "#FF0000",
                       "A P3 red outside sRGB clamps to the nearest sRGB value")
        XCTAssertEqual(colour(fromHex: "#3A7BD5").flatMap(hexString(for:)), "#3A7BD5")
        XCTAssertNil(colour(fromHex: "3A7BD5"))
        XCTAssertNil(colour(fromHex: "#3A7BDZ"))
    }

    @MainActor func testPickCopiesHexAndKeepsFiveRecentColoursForTheSession() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var next: NSColor?
        let picker = ColourPicker(pasteboard: pasteboard) { completion in completion(next) }
        var copied: [String] = []
        picker.onCopied = { copied.append($0) }
        for value in [10, 20, 30, 40, 50, 60] {
            next = NSColor(srgbRed: CGFloat(value) / 255, green: 0, blue: 0, alpha: 1)
            picker.pick()
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "#3C0000")
        XCTAssertEqual(picker.recent, ["#3C0000", "#320000", "#280000", "#1E0000", "#140000"])
        picker.copy("#1E0000")
        XCTAssertEqual(picker.recent.first, "#1E0000", "Copying a recent colour moves it to the front")
        XCTAssertEqual(picker.recent.count, 5)
        XCTAssertEqual(pasteboard.string(forType: .string), "#1E0000")
        XCTAssertEqual(copied.count, 7)
    }

    @MainActor func testCancellingTheSamplerCopiesNothing() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep me", forType: .string)
        let before = pasteboard.changeCount
        let picker = ColourPicker(pasteboard: pasteboard) { completion in completion(nil) }
        var cancelled = 0
        picker.onCancelled = { cancelled += 1 }
        picker.pick()
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertTrue(picker.recent.isEmpty)
    }

    @MainActor func testColourConfirmationShowsBrieflyWithoutActions() throws {
        _ = NSApplication.shared
        let presenter = CaptureStatusPresenter { _ in }
        presenter.update(ScreenWrenStatus(message: "ScreenWren — #3A7BD5 copied", swatch: colour(fromHex: "#3A7BD5")))
        let notice = try XCTUnwrap(presenter.notice, "A colour confirmation shows without needing attention")
        defer { notice.close() }
        var buttons: [NSButton] = []
        var labels: [String] = []
        var pending = notice.window?.contentView?.subviews ?? []
        while let view = pending.popLast() {
            if let button = view as? NSButton { buttons.append(button) }
            if let label = view as? NSTextField { labels.append(label.stringValue) }
            pending.append(contentsOf: view.subviews)
        }
        XCTAssertTrue(buttons.isEmpty)
        XCTAssertEqual(labels, ["#3A7BD5 copied"])
        presenter.update(ScreenWrenStatus(message: "ScreenWren — Captured and copied"))
        XCTAssertNil(presenter.notice, "Ordinary success stays quiet")
    }

    // MARK: Shortcuts and the settings bridge

    func testNewShortcutCommandsAreAppendedUnassigned() {
        XCTAssertEqual(ShortcutCommand.allCases.map(\.rawValue), [
            "capture", "copyText", "repeatCapture", "frontWindow", "freeze", "recents", "togglePins",
            "recordRegion", "pickColour",
        ])
        XCTAssertEqual(ShortcutCommand.allCases.map(\.identifier), Array(1...9))
        XCTAssertEqual(ShortcutCommand.recordRegion.title, "Record Region")
        XCTAssertEqual(ShortcutCommand.pickColour.title, "Pick Colour")
        XCTAssertNil(ShortcutCommand.recordRegion.defaultShortcut)
        XCTAssertNil(ShortcutCommand.pickColour.defaultShortcut)
    }

    @MainActor private func bridge(_ defaults: UserDefaults) -> MacToolsSettingsBridge {
        MacToolsSettingsBridge(defaults: defaults, loginState: { (false, "Off") }, setLoginEnabled: { _ in },
                               permissionState: { ["screenRecording": false] })
    }

    @MainActor func testBridgeListsTheNewCommandsAndStillAcceptsAnOldPatch() throws {
        let name = "ScreenWren.RecordingSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let snapshot = bridge(defaults).snapshot()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.shortcuts.map(\.command.rawValue).suffix(2), ["recordRegion", "pickColour"])
        XCTAssertEqual(snapshot.shortcuts.map(\.title).suffix(2), ["Record Region", "Pick Colour"])

        // What a manager that predates these commands sends: all seven old commands, unchanged keys.
        let old = #"{"captureDestination":"editor","shortcuts":[{"command":"capture","title":"Capture Region or Window","shortcut":{"keyCode":35,"carbonModifiers":4096,"keyEquivalent":"p","keyLabel":"P"}},{"command":"copyText","title":"Copy Text from Region","shortcut":null},{"command":"repeatCapture","title":"Repeat Last Capture","shortcut":null},{"command":"frontWindow","title":"Capture Front Window","shortcut":null},{"command":"freeze","title":"Freeze Screen & Select","shortcut":null},{"command":"recents","title":"Browse Recent Captures","shortcut":null},{"command":"togglePins","title":"Hide / Restore All Pins","shortcut":null}]}"#
        let written = try bridge(defaults).write(Data(old.utf8))
        XCTAssertEqual(written.captureDestination, .editor)
        XCTAssertEqual(written.shortcuts.count, 9)
        XCTAssertNil(written.shortcuts.first { $0.command == .recordRegion }?.shortcut)

        // The new commands take shortcuts through the same validation as the old ones.
        let assign = #"{"shortcuts":[{"command":"recordRegion","title":"Record Region","shortcut":{"keyCode":15,"carbonModifiers":4864,"keyEquivalent":"r","keyLabel":"R"}}]}"#
        let assigned = try bridge(defaults).write(Data(assign.utf8))
        XCTAssertEqual(assigned.shortcuts.first { $0.command == .recordRegion }?.shortcut?.keyLabel, "R")
        let clash = #"{"shortcuts":[{"command":"pickColour","title":"Pick Colour","shortcut":{"keyCode":15,"carbonModifiers":4864,"keyEquivalent":"r","keyLabel":"R"}}]}"#
        XCTAssertThrowsError(try bridge(defaults).write(Data(clash.utf8)))
        // Recording options are ScreenWren's own; the bridge does not take them.
        XCTAssertThrowsError(try bridge(defaults).write(Data(#"{"recordingFormat":"gif"}"#.utf8)))
    }

    // MARK: Recording

    @MainActor func testStreamConfigurationIsVideoOnlyAtDisplayScaleAndThirtyFPS() throws {
        let screen = try XCTUnwrap(NSScreen.main, "Needs a display")
        let rect = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 20, width: 400.5, height: 300)
        let region = try XCTUnwrap(DisplayRegion(rect: rect, screen: screen))
        let configuration = RegionStreamRecorder.configuration(for: region, displayFrame: CGDisplayBounds(region.displayID))
        XCTAssertFalse(configuration.capturesAudio, "No system audio")
        XCTAssertFalse(configuration.captureMicrophone, "No microphone")
        XCTAssertTrue(configuration.showsCursor)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        let expected = recordingStreamPixelSize(points: rect.size, scale: screen.backingScaleFactor)
        XCTAssertEqual(configuration.width, expected.width)
        XCTAssertEqual(configuration.height, expected.height)
        XCTAssertEqual(configuration.width % 2, 0)
        XCTAssertEqual(configuration.sourceRect.size, rect.size)
        XCTAssertEqual(configuration.sourceRect.minX, 10, accuracy: 0.001)
        XCTAssertEqual(configuration.sourceRect.maxY, screen.frame.height - 20, accuracy: 0.001,
                       "The source rectangle is measured from the display's top")
    }

    @MainActor func testCapturesWaitWhileARecordingIsActive() {
        _ = NSApplication.shared
        var shotsTaken = 0
        var services = CaptureServices()
        services.hasScreenAccess = { true }
        services.screenshot = { _ in shotsTaken += 1; throw CancellationError() }
        services.frontWindow = { XCTFail("No capture may start"); return nil }
        let coordinator = CaptureCoordinator(pasteboard: .withUniqueName(), services: services)
        var statuses: [String] = []
        coordinator.onStatus = { statuses.append($0.message) }
        coordinator.isRecording = { true }
        coordinator.primaryAction()
        coordinator.beginTextCapture()
        coordinator.captureFrontWindow()
        coordinator.beginFreezeCapture()
        coordinator.repeatLastCapture()
        coordinator.beginRecordingSelection { _ in XCTFail("No second recording") }
        XCTAssertFalse(coordinator.isSelecting)
        XCTAssertEqual(shotsTaken, 0)
        XCTAssertEqual(statuses.filter { $0.hasSuffix("Stop the recording first") }.count, 6)
    }

    @MainActor func testTimeLabelsAndFilenames() {
        _ = NSApplication.shared
        XCTAssertEqual(recordingTimeLabel(4.24), "0:04.2")
        XCTAssertEqual(recordingTimeLabel(299.96), "5:00.0")
        XCTAssertEqual(recordingFilename(for: Date(timeIntervalSince1970: 0), format: .gif).suffix(4), ".gif")
        XCTAssertTrue(recordingFilename(format: .mp4).hasPrefix("ScreenWren Recording "))
    }
}
