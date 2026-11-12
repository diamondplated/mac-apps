import AppKit
import SwiftUI

/// What the mixer shows. The app fills it from the engine; the render test from fakes.
public final class MixerViewModel: ObservableObject {
    public struct Row: Identifiable {
        public var id: String { bundleIdentifier }
        public var bundleIdentifier: String
        public var name: String
        public var icon: NSImage?
        public var volume: Double
        public var muted: Bool
        public var outputDeviceUID: String?
        public init(bundleIdentifier: String, name: String, icon: NSImage?, volume: Double, muted: Bool, outputDeviceUID: String?) {
            self.bundleIdentifier = bundleIdentifier; self.name = name; self.icon = icon
            self.volume = volume; self.muted = muted; self.outputDeviceUID = outputDeviceUID
        }
    }

    public struct SystemOutput {
        public var name: String
        /// nil when the device has no volume macOS can set.
        public var volume: Double?
        public init(name: String, volume: Double?) { self.name = name; self.volume = volume }
    }

    @Published public var rows: [Row] = []
    @Published public var outputs: [OutputDevice] = []
    @Published public var systemOutput: SystemOutput?
    @Published public var available = true
    @Published public var captureStatus: CaptureStatus = .unknown

    public var setVolume: (String, Double) -> Void = { _, _ in }
    public var toggleMute: (String) -> Void = { _ in }
    public var setOutput: (String, String?) -> Void = { _, _ in }
    public var setSystemVolume: (Double) -> Void = { _ in }
    public var openPrivacySettings: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var quit: () -> Void = {}

    public init() {}
}

public enum VolumeDetent {
    /// Values this close to 100 percent snap to it, so the app can be left untouched.
    public static let width = 0.04
    public static func snap(_ value: Double) -> Double {
        let clamped = min(max(value, AppVolume.range.lowerBound), AppVolume.range.upperBound)
        return abs(clamped - 1) < width ? 1 : clamped
    }
    public static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// The menu bar mixer: one row per app, then the system output, then Settings and Quit.
public struct MixerView: View {
    public static let width: CGFloat = 340
    @ObservedObject var model: MixerViewModel
    public init(model: MixerViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.available {
                Notice(text: "Needs macOS 14.2 or Later")
            } else if model.rows.isEmpty {
                Notice(text: "No Apps Playing Sound")
            } else {
                VStack(spacing: 4) {
                    ForEach(model.rows) { row in AppRowView(row: row, outputs: model.outputs, model: model) }
                }
                .padding(.vertical, 8)
            }
            if model.available && model.captureStatus == .denied {
                HStack(spacing: 8) {
                    Text("MixBar can’t hear other apps.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Allow…") { model.openPrivacySettings() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider().padding(.horizontal, 10)
            if let output = model.systemOutput {
                SystemOutputRow(output: output, model: model)
                    .padding(.vertical, 6)
                Divider().padding(.horizontal, 10)
            }
            HStack {
                Button("Settings…") { model.openSettings() }.keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit MixBar") { model.quit() }.keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
    }
}

private struct Notice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 22)
    }
}

private struct AppRowView: View {
    let row: MixerViewModel.Row
    let outputs: [OutputDevice]
    @ObservedObject var model: MixerViewModel

    private var outputName: String? {
        guard let uid = row.outputDeviceUID else { return nil }
        return outputs.first { $0.uid == uid }?.name ?? "Disconnected Output"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icon = row.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // The chosen output shows beside the name when both fit; otherwise the name wins.
                    ViewThatFits(in: .horizontal) {
                        if let outputName {
                            HStack(spacing: 6) {
                                Text(row.name).font(.body).lineLimit(1).fixedSize()
                                Text(outputName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                    .frame(minWidth: 60, alignment: .leading)
                            }
                        }
                        Text(row.name).font(.body).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Text(row.muted ? "Muted" : VolumeDetent.percent(row.volume))
                        .font(.subheadline.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                DetentSlider(value: Binding(get: { row.volume }, set: { model.setVolume(row.bundleIdentifier, VolumeDetent.snap($0)) }),
                             range: AppVolume.range, detent: 1)
                    .opacity(row.muted ? 0.45 : 1)
                    .accessibilityLabel("\(row.name) Volume")
                    .accessibilityValue(row.muted ? "Muted" : VolumeDetent.percent(row.volume))
            }
            Button { model.toggleMute(row.bundleIdentifier) } label: {
                Image(systemName: row.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
                    .foregroundStyle(row.muted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(row.muted ? "Unmute" : "Mute")
            .accessibilityLabel(row.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
            Menu {
                Picker("Output", selection: Binding(get: { row.outputDeviceUID }, set: { model.setOutput(row.bundleIdentifier, $0) })) {
                    Text("System Default").tag(String?.none)
                    if !outputs.isEmpty { Divider() }
                    ForEach(outputs) { device in Text(device.name).tag(String?.some(device.uid)) }
                    if let uid = row.outputDeviceUID, !outputs.contains(where: { $0.uid == uid }) {
                        Text("Disconnected Output").tag(String?.some(uid))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: row.outputDeviceUID == nil ? "hifispeaker" : "hifispeaker.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Output: \(outputName ?? "System Default")")
            .accessibilityLabel("\(row.name) Output, \(outputName ?? "System Default")")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct SystemOutputRow: View {
    let output: MixerViewModel.SystemOutput
    @ObservedObject var model: MixerViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(output.name).font(.body).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let volume = output.volume {
                        Text(VolumeDetent.percent(volume)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                if let volume = output.volume {
                    Slider(value: Binding(get: { volume }, set: { model.setSystemVolume(min(max($0, 0), 1)) }), in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("\(output.name) Volume")
                        .accessibilityValue(VolumeDetent.percent(volume))
                } else {
                    Text("Volume Set on the Device").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            // Keeps the slider the same width as the app rows above.
            Color.clear.frame(width: 47, height: 1)
        }
        .padding(.horizontal, 14)
    }
}

/// A small slider with a tick under its detent.
private struct DetentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let detent: Double

    var body: some View {
        Slider(value: $value, in: range)
            .controlSize(.small)
            .background(alignment: .bottom) {
                GeometryReader { proxy in
                    // The small slider's knob is about 14 points wide; the track's ends sit half a knob in.
                    let inset: CGFloat = 7
                    let fraction = (detent - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Capsule()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 2, height: 4)
                        .position(x: inset + (proxy.size.width - inset * 2) * fraction, y: proxy.size.height / 2 + 6)
                }
                .accessibilityHidden(true)
            }
    }
}
