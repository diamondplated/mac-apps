import AppKit
import SwiftUI
import XCTest
@testable import MixBarCore

/// Renders the mixer offscreen with five fake apps. With MIXBAR_MIXER_SNAPSHOT=/dir/name.png
/// it also writes name-{light,dark}-{mixer,empty,denied}.png beside it.
final class MixerRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func icon(_ path: String, fallback symbol: String) -> NSImage? {
        if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func fiveApps() -> MixerViewModel {
        let model = MixerViewModel()
        model.outputs = [OutputDevice(uid: "speakers", name: "MacBook Pro Speakers"), OutputDevice(uid: "studio", name: "Studio Display Speakers"),
                         OutputDevice(uid: "airpods", name: "AirPods Pro")]
        model.rows = [
            .init(bundleIdentifier: "com.apple.Music", name: "Music", icon: icon("/System/Applications/Music.app", fallback: "music.note"),
                  volume: 0.6, muted: false, outputDeviceUID: nil),
            .init(bundleIdentifier: "com.apple.podcasts", name: "Podcasts", icon: icon("/System/Applications/Podcasts.app", fallback: "mic"),
                  volume: 1.45, muted: false, outputDeviceUID: "airpods"),
            .init(bundleIdentifier: "com.apple.Safari", name: "Safari", icon: icon("/Applications/Safari.app", fallback: "safari"),
                  volume: 1, muted: false, outputDeviceUID: nil),
            .init(bundleIdentifier: "com.apple.TV", name: "TV", icon: icon("/System/Applications/TV.app", fallback: "tv"),
                  volume: 0.8, muted: true, outputDeviceUID: "studio"),
            .init(bundleIdentifier: "com.example.long", name: "An App With A Name Far Too Long To Fit On One Row", icon: nil,
                  volume: 2, muted: false, outputDeviceUID: "unplugged")
        ]
        model.systemOutput = .init(name: "MacBook Pro Speakers", volume: 0.5)
        model.captureStatus = .granted
        return model
    }

    func testMixerRendersInBothAppearances() throws {
        let path = ProcessInfo.processInfo.environment["MIXBAR_MIXER_SNAPSHOT"]
        let empty = MixerViewModel()
        empty.systemOutput = .init(name: "External Headphones", volume: nil)
        let denied = fiveApps()
        denied.rows = Array(denied.rows.prefix(2))
        denied.captureStatus = .denied
        let unavailable = MixerViewModel()
        unavailable.available = false
        let models: [(String, MixerViewModel)] = [("mixer", fiveApps()), ("empty", empty), ("denied", denied), ("unavailable", unavailable)]
        for (name, model) in models {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let root = MixerView(model: model).background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: root)
                hosting.appearance = NSAppearance(named: appearance)
                let size = hosting.fittingSize
                XCTAssertEqual(size.width, MixerView.width, accuracy: 1, "\(name) \(mode)")
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                defer { window.contentView = nil }
                hosting.layoutSubtreeIfNeeded()
                if name == "mixer" {
                    // Five rows of about 44 points, the system output and the buttons: no row wraps.
                    XCTAssertLessThan(size.height, 400, "\(mode): a long name must not wrap")
                    XCTAssertGreaterThan(size.height, 300, "\(mode): five rows shown")
                }
                guard let path else { continue }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let base = URL(fileURLWithPath: path).deletingPathExtension().path
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(base)-\(mode)-\(name).png"))
            }
        }
    }
}
