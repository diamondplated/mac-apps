import AppKit
import MacToolsCore
import SwiftUI

struct ToolSettingsView: View {
    @ObservedObject var library: LibraryModel
    @StateObject private var settings = ToolSettingsModel()
    @State private var width = ""
    @State private var height = ""
    @State private var presetName = ""

    private var app: ManagedApp { library.settingsApp }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("One place to make them yours.").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Settings are shared with each tool and take effect when you save.").foregroundStyle(.secondary)
            }
            Picker("Tool", selection: $library.settingsApp) {
                ForEach(ManagedApp.allCases) { app in Text(app.name).tag(app) }
            }.pickerStyle(.segmented).disabled(settings.loading || settings.saving || library.isBusy)
            if settings.loading {
                ProgressView("Loading settings…").frame(maxWidth: .infinity, minHeight: 180)
            } else if let snapshot = settings.snapshot, snapshot.app == app.rawValue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("Startup", symbol: "power") {
                            Toggle("Launch \(app.name) when I log in", isOn: boolBinding(snapshot.launchAtLogin, key: "launchAtLogin"))
                            Text(loginDescription(snapshot.loginStatus)).font(.caption).foregroundStyle(.secondary)
                            if snapshot.loginStatus.lowercased().contains("approval") {
                                Button("Open Login Items") { library.openSettings("com.apple.LoginItems-Settings.extension") }
                            }
                        }
                        if app == .dockPeek { dockSettings(snapshot) }
                        else { captureSettings(snapshot); selectionSettings(snapshot); shortcutSettings(snapshot) }
                        permissions
                    }.padding(.trailing, 3)
                }.frame(minHeight: 400)
                .disabled(settings.saving || library.isBusy)
                if let message = settings.message {
                    Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = settings.error {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    if settings.snapshot == nil {
                        Text("Install or update this tool from All Apps to use its settings here.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh Settings") { Task { await load() } }.disabled(settings.saving || library.isBusy)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: app) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !settings.saving, !library.isBusy else { return }
            Task { await load() }
        }
    }

    private func load() async {
        await settings.load(app, library: library)
        synchronizeDimensions()
    }

    private func save(_ values: [String: Any]) {
        let selectedApp = app
        Task { await settings.save(values, app: selectedApp, library: library); synchronizeDimensions() }
    }

    private func synchronizeDimensions() {
        if let w = settings.snapshot?.selectionWidth, w > 0 { width = String(w) } else { width = "" }
        if let h = settings.snapshot?.selectionHeight, h > 0 { height = String(h) } else { height = "" }
    }

    private func boolBinding(_ current: Bool, key: String) -> Binding<Bool> {
        Binding(get: { current }, set: { save([key: $0]) })
    }

    private func loginDescription(_ value: String) -> String {
        switch value {
        case "enabled": "On"
        case "notRegistered", "notFound": "Off"
        case "requiresApproval": "Needs approval in System Settings"
        case "unknown": "Status unavailable"
        default: value
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: symbol).font(.headline)
                content()
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dockSettings(_ value: ToolSettingsSnapshot) -> some View {
        section("Dock previews", symbol: "macwindow.on.rectangle") {
            Toggle("Show window previews when I hover the Dock", isOn: boolBinding(value.previewsEnabled ?? true, key: "previewsEnabled"))
            Toggle("Include browser and app tabs", isOn: boolBinding(value.showsTabs ?? true, key: "showsTabs"))
            HStack {
                Text("Keep previews open after leaving")
                Spacer()
                Picker("Dismissal delay", selection: Binding(get: { value.dismissalDelay ?? 0.6 }, set: { save(["dismissalDelay": $0]) })) {
                    ForEach([0.2, 0.4, 0.6, 1.0, 1.5, 2.0, 3.0], id: \.self) { delay in
                        Text("\(delay, specifier: "%.1f") seconds").tag(delay)
                    }
                    if let current = value.dismissalDelay, ![0.2, 0.4, 0.6, 1.0, 1.5, 2.0, 3.0].contains(current) {
                        Text("\(current, specifier: "%.2f") seconds").tag(current)
                    }
                }.labelsHidden().frame(width: 140)
            }
            Button("Restore Preview Defaults") { save(["previewsEnabled": true, "showsTabs": true, "dismissalDelay": 0.6]) }
                .font(.caption)
        }
    }

    private func captureSettings(_ value: ToolSettingsSnapshot) -> some View {
        section("Capture", symbol: "viewfinder") {
            Picker("After capture", selection: Binding(get: { value.captureDestination ?? "clipboard" }, set: { save(["captureDestination": $0]) })) {
                Text("Copy only").tag("clipboard")
                Text("Copy and open editor").tag("editor")
                Text("Copy and pin").tag("pin")
                Text("Save…").tag("save")
                Text("Review redactions before copying").tag("review")
            }
            Toggle("Show a quick-action thumbnail for 6 seconds", isOn: boolBinding(value.showsThumbnail ?? false, key: "showsThumbnail"))
            Toggle("Adjust the selection before capturing", isOn: boolBinding(value.adjustBeforeCapture ?? false, key: "adjustBeforeCapture"))
            Text("Save asks where to put the image. Review waits for your redaction check before copying.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectionSettings(_ value: ToolSettingsSnapshot) -> some View {
        section("Selection & saved sizes", symbol: "crop") {
            HStack(spacing: 8) {
                Text("Exact pixels").frame(width: 90, alignment: .leading)
                TextField("Free", text: $width).frame(width: 76).accessibilityLabel("Selection width in pixels")
                Text("×").foregroundStyle(.secondary)
                TextField("Free", text: $height).frame(width: 76).accessibilityLabel("Selection height in pixels")
                Button("Apply") { applySize() }
                Button("Free") { save(["selectionWidth": 0, "selectionHeight": 0]) }
            }.textFieldStyle(.roundedBorder)
            Picker("Aspect ratio", selection: Binding(get: { value.aspectRatio ?? 0 }, set: { save(["aspectRatio": $0]) })) {
                Text("Free").tag(0.0)
                Text("Square · 1:1").tag(1.0)
                Text("16:9").tag(16.0 / 9)
                Text("4:3").tag(4.0 / 3)
                Text("3:2").tag(1.5)
                if let current = value.aspectRatio, ![0, 1, 16.0 / 9, 4.0 / 3, 1.5].contains(current) {
                    Text("Custom · \(current, specifier: "%.3f")").tag(current)
                }
            }
            ForEach(value.presets ?? []) { preset in
                HStack {
                    Text(preset.name)
                    Spacer()
                    Text("\(preset.width) × \(preset.height)").font(.caption).foregroundStyle(.secondary)
                    Button("Use") { save(["selectionWidth": preset.width, "selectionHeight": preset.height]) }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        savePresets((value.presets ?? []).filter { $0.name != preset.name })
                    }.labelStyle(.iconOnly).help("Remove \(preset.name)")
                }
            }
            HStack {
                TextField("Name this size", text: $presetName).textFieldStyle(.roundedBorder)
                Button("Save Size Preset") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name.count <= 60, let w = Int(width), let h = Int(height), (4...16_000).contains(w), (4...16_000).contains(h) else {
                        settings.error = "Enter a name and both dimensions from 4 to 16,000 pixels."
                        return
                    }
                    var presets = (value.presets ?? []).filter { $0.name != name }
                    presets.insert(SizePreset(name: name, width: w, height: h), at: 0)
                    guard presets.count <= 20 else { settings.error = "You can save up to 20 sizes. Remove one first."; return }
                    savePresets(presets)
                    presetName = ""
                }
            }
            Text("Dimensions range from 4 to 16,000 pixels and are clipped to the available desktop. A fixed size takes priority over the aspect ratio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func applySize() {
        guard let w = Int(width), let h = Int(height), (4...16_000).contains(w), (4...16_000).contains(h) else {
            settings.error = "Enter both dimensions from 4 to 16,000 pixels, or choose Free."
            return
        }
        save(["selectionWidth": w, "selectionHeight": h])
    }

    private func savePresets(_ presets: [SizePreset]) {
        do {
            let data = try JSONEncoder().encode(presets)
            save(["presets": try JSONSerialization.jsonObject(with: data)])
        } catch { settings.error = error.localizedDescription }
    }

    private func shortcutSettings(_ value: ToolSettingsSnapshot) -> some View {
        section("Keyboard shortcuts", symbol: "keyboard") {
            ForEach(value.shortcuts ?? []) { shortcut in
                HStack {
                    Text(shortcut.title)
                    Spacer()
                    ShortcutRecorder(shortcut: shortcut.shortcut, title: shortcut.title) { recorded in
                        let selectedApp = app
                        Task { await settings.updateShortcut(shortcut.command, value: recorded, app: selectedApp, library: library) }
                    }.frame(width: 145, height: 27)
                }
            }
            Text("Click a shortcut and press the keys you want. Include Command, Control, or Option. Delete clears it; Escape cancels.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore Default Shortcuts") { save(["resetShortcuts": true]) }.font(.caption)
        }
    }

    private var permissions: some View {
        section("macOS permissions", symbol: "lock.shield") {
            Text(app == .dockPeek ? "DockPeek needs Accessibility and Screen Recording to preview and switch windows." : "ScreenWren needs Screen Recording to capture the screen.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if app == .dockPeek {
                    Button("Accessibility") { library.openSettings("com.apple.preference.security?Privacy_Accessibility") }
                }
                Button("Screen Recording") { library.openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
                Button("Login Items") { library.openSettings("com.apple.LoginItems-Settings.extension") }
            }
        }
    }
}
