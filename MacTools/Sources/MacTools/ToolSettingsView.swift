import AppKit
import MacToolsCore
import SwiftUI

struct ToolSettingsView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var settings: ToolSettingsModel

    init(library: LibraryModel) {
        self.library = library
        self.settings = library.toolSettings
    }
    @State private var width = ""
    @State private var height = ""
    @State private var presetName = ""
    @State private var scrollSpeed = 1.0
    private var hasUnsavedRoutes: Bool { settings.hasUnsavedRoutes }

    private var app: ManagedApp { library.settingsApp }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("One place to make them yours.").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Settings are shared with each tool and take effect when you save.").foregroundStyle(.secondary)
            }
            Picker("Tool", selection: $library.settingsApp) {
                ForEach(ManagedApp.allCases) { app in Text(app.name).tag(app) }
            }.pickerStyle(.segmented).disabled(settings.loading || settings.saving || library.isBusy || (app == .linkRoutes && hasUnsavedRoutes))
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
                        switch app {
                        case .dockPeek: dockSettings(snapshot)
                        case .screenWren:
                            captureSettings(snapshot)
                            selectionSettings(snapshot)
                            shortcutSettings(snapshot)
                        case .scrollSplit: scrollSettings(snapshot)
                        case .linkRoutes: linkSettings(snapshot)
                        }
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
            guard !settings.saving, !library.isBusy, !hasUnsavedRoutes else { return }
            Task { await load() }
        }
    }

    private func load() async {
        await settings.load(app, library: library)
        synchronizeDimensions()
        if app == .linkRoutes, let rules = settings.snapshot?.rules {
            settings.synchronizeRouteDraft(rules)
        }
        scrollSpeed = settings.snapshot?.speedMultiplier ?? 1
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

    private func scrollSettings(_ value: ToolSettingsSnapshot) -> some View {
        section("Mouse scrolling", symbol: "computermouse") {
            Toggle("Customize mouse scrolling", isOn: boolBinding(value.enabled ?? false, key: "enabled"))
            Text("These controls apply to mouse wheel events. Trackpad scrolling keeps its macOS behavior.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Reverse vertical scrolling", isOn: boolBinding(value.reverseVertical ?? false, key: "reverseVertical"))
            Toggle("Reverse horizontal scrolling", isOn: boolBinding(value.reverseHorizontal ?? false, key: "reverseHorizontal"))
            HStack {
                Text("Scroll speed")
                Slider(value: $scrollSpeed, in: 0.25...4, step: 0.05, onEditingChanged: { editing in
                    if !editing { save(["speedMultiplier": scrollSpeed]) }
                }).accessibilityLabel("Mouse scroll speed")
                Text("\(scrollSpeed, specifier: "%.2f")×").monospacedDigit().frame(width: 55)
            }
            Button("Reset Mouse Scrolling") {
                scrollSpeed = 1
                save(["reverseVertical": false, "reverseHorizontal": false, "speedMultiplier": 1])
            }.font(.caption)
            if let active = value.liveEventTapActive {
                Label(active ? "Scroll customization is active" : "Open ScrollSplit to activate scrolling and check permissions",
                      systemImage: active ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Open ScrollSplit") { Task { await library.launch(.scrollSplit) } }
        }
    }

    private func linkSettings(_ value: ToolSettingsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Browser routing", symbol: "arrow.triangle.branch") {
                Label(value.isDefaultBrowser == true ? "LinkRoutes handles links from other apps" : "Set up LinkRoutes to handle links from other apps",
                      systemImage: value.isDefaultBrowser == true ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(.secondary)
                Button("Open LinkRoutes Setup") { Task { await library.launch(.linkRoutes) } }
                browserPicker("Fallback browser", selection: Binding(
                    get: { value.defaultBrowserIdentifier ?? "" },
                    set: { save(["defaultBrowserIdentifier": $0]) }
                ), browsers: value.availableBrowsers ?? [])
                Text("Links that do not match a rule open in the fallback browser. Browser selection for macOS is completed in LinkRoutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("Website rules", symbol: "list.bullet.indent") {
                Text("The first matching rule wins. Move specific websites above broader rules, then save the list.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.routeRules.isEmpty {
                    Label("Add a website to start routing your links.", systemImage: "link.badge.plus")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach($settings.routeRules) { $rule in
                    routeRow($rule, browsers: value.availableBrowsers ?? [])
                    Divider()
                }
                HStack {
                    Button("Add Website", systemImage: "plus") {
                        settings.routeRules.append(BrowserRouteRule(domain: "", browserIdentifier: value.defaultBrowserIdentifier ?? value.availableBrowsers?.first?.identifier ?? ""))
                    }
                    Spacer()
                    Button("Discard Changes") { settings.discardRouteChanges() }.disabled(!hasUnsavedRoutes)
                    Button("Save Rules") { saveRoutes() }.buttonStyle(.borderedProminent).disabled(!hasUnsavedRoutes)
                }
                if hasUnsavedRoutes {
                    Text("You have unsaved rules. Save or discard them before switching tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func browserPicker(_ title: String, selection: Binding<String>, browsers: [AvailableBrowser]) -> some View {
        Picker(title, selection: selection) {
            if selection.wrappedValue.isEmpty { Text("Choose a browser").tag("") }
            ForEach(browsers) { browser in Text(browser.name).tag(browser.identifier) }
            if !selection.wrappedValue.isEmpty, !browsers.contains(where: { $0.identifier == selection.wrappedValue }) {
                Text("Unavailable · \(selection.wrappedValue)").tag(selection.wrappedValue)
            }
        }
    }

    private func routeRow(_ rule: Binding<BrowserRouteRule>, browsers: [AvailableBrowser]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("example.com", text: rule.domain).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Website domain")
                Button("Move Rule Up", systemImage: "chevron.up") { moveRule(rule.wrappedValue.id, by: -1) }
                    .labelStyle(.iconOnly).disabled(settings.routeRules.first?.id == rule.wrappedValue.id)
                Button("Move Rule Down", systemImage: "chevron.down") { moveRule(rule.wrappedValue.id, by: 1) }
                    .labelStyle(.iconOnly).disabled(settings.routeRules.last?.id == rule.wrappedValue.id)
                Button("Remove Website", systemImage: "trash", role: .destructive) {
                    settings.routeRules.removeAll { $0.id == rule.wrappedValue.id }
                }.labelStyle(.iconOnly)
            }
            Toggle("Include subdomains", isOn: rule.includeSubdomains).font(.caption)
            browserPicker("Open in", selection: Binding(
                get: { rule.wrappedValue.browserIdentifier },
                set: { rule.wrappedValue.browserIdentifier = $0; rule.wrappedValue.profileDirectory = nil }
            ), browsers: browsers)
            let profiles = browsers.first(where: { $0.identifier == rule.wrappedValue.browserIdentifier })?.profiles ?? []
            if !profiles.isEmpty || rule.wrappedValue.profileDirectory != nil {
                Picker("Profile", selection: Binding(
                    get: { rule.wrappedValue.profileDirectory ?? "" },
                    set: { rule.wrappedValue.profileDirectory = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Browser default").tag("")
                    ForEach(profiles) { profile in Text(profile.name).tag(profile.directory) }
                    if let current = rule.wrappedValue.profileDirectory, !profiles.contains(where: { $0.directory == current }) {
                        Text("Unavailable · \(current)").tag(current)
                    }
                }
            }
        }.padding(.vertical, 4)
    }

    private func moveRule(_ id: String, by offset: Int) {
        guard let index = settings.routeRules.firstIndex(where: { $0.id == id }), settings.routeRules.indices.contains(index + offset) else { return }
        settings.routeRules.swapAt(index, index + offset)
    }

    private func saveRoutes() {
        let selectedApp = app
        let draft = settings.routeRules
        Task {
            do {
                let data = try JSONEncoder().encode(draft)
                let rules = try JSONSerialization.jsonObject(with: data)
                await settings.save(["rules": rules], app: selectedApp, library: library)
                if settings.error == nil, app == selectedApp {
                    settings.acceptSavedRoutes(settings.snapshot?.rules ?? draft)
                }
            } catch { settings.error = error.localizedDescription }
        }
    }

    private var permissionDescription: String {
        switch app {
        case .dockPeek: "DockPeek needs Accessibility and Screen Recording to preview and switch windows."
        case .screenWren: "ScreenWren needs Screen Recording to capture the screen."
        case .scrollSplit: "ScrollSplit uses Accessibility and Input Monitoring to adjust mouse scrolling. Grant access to ScrollSplit, then reopen it."
        case .linkRoutes: "LinkRoutes uses your chosen browser and routing rules. Manage its startup behavior in Login Items."
        }
    }

    private var permissions: some View {
        section("macOS permissions", symbol: "lock.shield") {
            Text(permissionDescription).font(.callout).foregroundStyle(.secondary)
            if app == .scrollSplit, let snapshot = settings.snapshot {
                Text(snapshot.scrollPermissionContext).font(.caption).foregroundStyle(.secondary)
                if snapshot.hasLiveScrollPermissions, let status = snapshot.permissions {
                    HStack(spacing: 16) {
                        permissionStatus("Accessibility", granted: status["accessibility"])
                        permissionStatus("Input Monitoring", granted: status["inputMonitoring"])
                    }
                }
            }
            HStack {
                if app == .dockPeek || app == .scrollSplit {
                    Button("Accessibility") { library.openSettings("com.apple.preference.security?Privacy_Accessibility") }
                }
                if app == .dockPeek || app == .screenWren {
                    Button("Screen Recording") { library.openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
                }
                if app == .scrollSplit {
                    Button("Input Monitoring") { library.openSettings("com.apple.preference.security?Privacy_ListenEvent") }
                }
                Button("Login Items") { library.openSettings("com.apple.LoginItems-Settings.extension") }
            }
        }
    }

    private func permissionStatus(_ title: String, granted: Bool?) -> some View {
        Label(granted == nil ? "\(title) · Unknown" : title, systemImage: granted == true ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(granted == true ? Color.green : Color.secondary)
    }
}
