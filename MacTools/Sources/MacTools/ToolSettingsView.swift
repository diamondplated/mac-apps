import AppKit
import MacToolsCore
import SwiftUI

/// The settings sections for one menu bar utility. Place it inside a grouped `Form`.
/// Every change is written through the app's own settings bridge as soon as it is made.
struct ToolSettingsView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var settings: ToolSettingsModel
    private let explicitApp: ManagedApp?

    init(library: LibraryModel, app: ManagedApp? = nil) {
        self.library = library
        self.settings = library.toolSettings
        self.explicitApp = app
    }

    private var app: ManagedApp { explicitApp ?? library.settingsApp }

    var body: some View {
        if let snapshot = settings.snapshot, snapshot.app == app.rawValue {
            switch app {
            case .dockPeek: dockSettings(snapshot)
            case .screenWren:
                captureSettings(snapshot)
                selectionSettings(snapshot)
                shortcutSettings(snapshot)
            case .scrollSplit: scrollSettings(snapshot)
            case .linkRoutes: linkSettings(snapshot)
            case .latent, .sift: EmptyView()
            }
            general(snapshot)
            permissions(snapshot)
        } else if let error = settings.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await settings.load(app, library: library) } }
            }
        } else {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading settings…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save(_ values: [String: Any]) {
        let selectedApp = app
        Task { await settings.save(values, app: selectedApp, library: library) }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A control bound to one setting. It shows the new value at once and writes it in turn.
    private func setting<Value>(_ current: Value, key: String) -> Binding<Value> {
        Binding(get: { settings.pending[key] as? Value ?? current }, set: { save([key: $0]) })
    }

    private func toggle(_ current: Bool, key: String) -> Binding<Bool> { setting(current, key: key) }

    // MARK: Shared

    private func general(_ value: ToolSettingsSnapshot) -> some View {
        Section("General") {
            Toggle("Open at login", isOn: toggle(value.launchAtLogin, key: "launchAtLogin"))
            if value.loginStatus == "requiresApproval" {
                LabeledContent("Needs approval in System Settings") {
                    Button("Open Login Items") { library.openSettings("com.apple.LoginItems-Settings.extension") }
                }
            }
        }
    }

    private struct Requirement {
        let key: String
        let title: String
        let pane: String
    }

    private var requirements: [Requirement] {
        let accessibility = Requirement(key: "accessibility", title: "Accessibility", pane: "com.apple.preference.security?Privacy_Accessibility")
        let screen = Requirement(key: "screenRecording", title: "Screen Recording", pane: "com.apple.preference.security?Privacy_ScreenCapture")
        let input = Requirement(key: "inputMonitoring", title: "Input Monitoring", pane: "com.apple.preference.security?Privacy_ListenEvent")
        switch app {
        case .dockPeek: return [accessibility, screen]
        case .screenWren: return [screen]
        case .scrollSplit: return [accessibility, input]
        case .linkRoutes, .latent, .sift: return []
        }
    }

    @ViewBuilder
    private func permissions(_ value: ToolSettingsSnapshot) -> some View {
        if !requirements.isEmpty {
            Section {
                ForEach(requirements, id: \.key) { requirement in
                    LabeledContent(requirement.title) {
                        HStack(spacing: 10) {
                            // Shown only when the running app itself reported it.
                            switch value.permission(requirement.key) {
                            case true?: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case false?: Text("Not allowed").foregroundStyle(.orange)
                            case nil: EmptyView()
                            }
                            Button("Open Settings") { library.openSettings(requirement.pane) }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                footnote(app == .scrollSplit && !value.hasLiveScrollPermissions
                    ? value.scrollPermissionContext : "After changing access, quit and reopen \(app.name).")
            }
        }
    }

    // MARK: DockPeek

    private static let dismissalDelays = [0.2, 0.4, 0.6, 1.0, 1.5, 2.0, 3.0]

    @ViewBuilder
    private func dockSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section("Previews") {
            Toggle("Show window previews when hovering the Dock", isOn: toggle(value.previewsEnabled ?? true, key: "previewsEnabled"))
            Toggle("Show browser tabs", isOn: toggle(value.showsTabs ?? true, key: "showsTabs"))
            Picker("Keep previews open after leaving", selection: setting(value.dismissalDelay ?? 0.6, key: "dismissalDelay")) {
                ForEach(Self.dismissalDelays, id: \.self) { delay in
                    Text("\(delay, specifier: "%.1f") seconds").tag(delay)
                }
                if let current = value.dismissalDelay, !Self.dismissalDelays.contains(current) {
                    Text("\(current, specifier: "%.2f") seconds").tag(current)
                }
            }
        }
        // Shown only when the installed DockPeek has these features.
        if let switcher = value.switcherEnabled {
            Section {
                Toggle("Switch windows with ⌥Tab", isOn: toggle(switcher, key: "switcherEnabled"))
            } header: {
                Text("Window Switcher")
            } footer: {
                footnote("Hold Option and press Tab to move through every open window. Release Option to switch.")
            }
        }
        if value.dockClickHidesFrontApp != nil || value.dockScrollCyclesWindows != nil || value.dockMiddleClickOpensWindow != nil {
            Section {
                if let hides = value.dockClickHidesFrontApp {
                    Toggle("Click the front app’s icon to hide it", isOn: toggle(hides, key: "dockClickHidesFrontApp"))
                }
                if let cycles = value.dockScrollCyclesWindows {
                    Toggle("Scroll on an icon to cycle its windows", isOn: toggle(cycles, key: "dockScrollCyclesWindows"))
                }
                if let opens = value.dockMiddleClickOpensWindow {
                    Toggle("Middle-click an icon for a new window", isOn: toggle(opens, key: "dockMiddleClickOpensWindow"))
                }
            } header: {
                Text("Dock Clicks")
            } footer: {
                footnote("These change what the Dock normally does, so they start off.")
            }
        }
    }

    // MARK: ScreenWren

    private func captureSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section("Capture") {
            Picker("After capturing", selection: setting(value.captureDestination ?? "clipboard", key: "captureDestination")) {
                Text("Copy").tag("clipboard")
                Text("Copy and open the editor").tag("editor")
                Text("Copy and pin").tag("pin")
                Text("Ask where to save").tag("save")
                Text("Review redactions, then copy").tag("review")
            }
            Toggle("Show a thumbnail with quick actions", isOn: toggle(value.showsThumbnail ?? false, key: "showsThumbnail"))
            Toggle("Adjust the selection before capturing", isOn: toggle(value.adjustBeforeCapture ?? false, key: "adjustBeforeCapture"))
        }
    }

    private static let aspectRatios = [0, 1, 16.0 / 9, 4.0 / 3, 1.5]

    private func selectionSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section {
            LabeledContent("Fixed size") {
                HStack(spacing: 6) {
                    TextField("Width", text: $settings.selectionWidth, prompt: Text("Width")).frame(width: 64)
                        .accessibilityLabel("Selection width in pixels")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $settings.selectionHeight, prompt: Text("Height")).frame(width: 64)
                        .accessibilityLabel("Selection height in pixels")
                    Button("Set") { applySize() }
                    if (value.selectionWidth ?? 0) > 0 {
                        Button("Clear") { save(["selectionWidth": 0, "selectionHeight": 0]) }
                    }
                }
                .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.trailing)
            }
            Picker("Aspect ratio", selection: setting(value.aspectRatio ?? 0, key: "aspectRatio")) {
                Text("Free").tag(0.0)
                Text("Square").tag(1.0)
                Text("16:9").tag(16.0 / 9)
                Text("4:3").tag(4.0 / 3)
                Text("3:2").tag(1.5)
                if let current = value.aspectRatio, !Self.aspectRatios.contains(current) {
                    Text("Custom (\(current, specifier: "%.3f"))").tag(current)
                }
            }
            ForEach(value.presets ?? []) { preset in
                LabeledContent {
                    HStack(spacing: 10) {
                        Text("\(preset.width) × \(preset.height)").foregroundStyle(.secondary).monospacedDigit()
                        Button("Use") { save(["selectionWidth": preset.width, "selectionHeight": preset.height]) }
                        Button("Remove \(preset.name)", systemImage: "minus.circle", role: .destructive) {
                            editPresets(from: value.presets ?? []) { $0.filter { $0.name != preset.name } }
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                } label: { Text(preset.name) }
            }
            LabeledContent("Save this size as") {
                HStack(spacing: 6) {
                    TextField("Name", text: $settings.presetName, prompt: Text("Name")).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 150)
                    Button("Save") { addPreset(from: value.presets ?? []) }
                        .disabled(settings.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Selection size")
        } footer: {
            footnote("A fixed size wins over the aspect ratio.")
        }
    }

    private func dimensions() -> (Int, Int)? {
        guard let w = Int(settings.selectionWidth), let h = Int(settings.selectionHeight),
              (4...16_000).contains(w), (4...16_000).contains(h) else { return nil }
        return (w, h)
    }

    private func applySize() {
        guard let (w, h) = dimensions() else {
            library.error = "Enter a width and height from 4 to 16,000 pixels."
            return
        }
        save(["selectionWidth": w, "selectionHeight": h])
    }

    private func addPreset(from shown: [SizePreset]) {
        let name = settings.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, let (w, h) = dimensions() else {
            library.error = "Enter a name, and a width and height from 4 to 16,000 pixels."
            return
        }
        guard shown.filter({ $0.name != name }).count < 20 else {
            library.error = "You can save up to 20 sizes. Remove one first."
            return
        }
        editPresets(from: shown) { presets in
            [SizePreset(name: name, width: w, height: h)] + presets.filter { $0.name != name }
        }
        settings.presetName = ""
    }

    /// Changes the saved sizes starting from whatever is saved when this edit's turn comes,
    /// so removing two in a row removes both. `shown` is used if the page has moved on.
    private func editPresets(from shown: [SizePreset], _ change: @escaping ([SizePreset]) -> [SizePreset]) {
        let selectedApp = app
        Task {
            await settings.save(app: selectedApp, library: library) { latest in
                guard let data = try? JSONEncoder().encode(change(latest?.presets ?? shown)),
                      let presets = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return ["presets": presets]
            }
        }
    }

    private func shortcutSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section {
            ForEach(value.shortcuts ?? []) { shortcut in
                LabeledContent(shortcut.title) {
                    ShortcutRecorder(shortcut: shortcut.shortcut, title: shortcut.title) { recorded in
                        let selectedApp = app
                        Task { await settings.updateShortcut(shortcut.command, value: recorded, app: selectedApp, library: library) }
                    }.frame(width: 130)
                }
            }
            Button("Restore Defaults") { save(["resetShortcuts": true]) }
        } header: {
            Text("Shortcuts")
        } footer: {
            footnote("Click a shortcut, then press the new keys. Delete clears it.")
        }
    }

    // MARK: ScrollSplit

    private func scrollSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section {
            Toggle("Change mouse wheel scrolling", isOn: toggle(value.enabled ?? false, key: "enabled"))
            // ScrollSplit itself reverses vertical scrolling until told otherwise.
            Toggle("Reverse vertical", isOn: toggle(value.reverseVertical ?? true, key: "reverseVertical"))
            Toggle("Reverse horizontal", isOn: toggle(value.reverseHorizontal ?? false, key: "reverseHorizontal"))
            LabeledContent("Speed") {
                HStack(spacing: 10) {
                    // No `step`: it draws a tick for every stop. Snap when the drag ends instead.
                    Slider(value: $settings.scrollSpeed, in: 0.25...4, onEditingChanged: { editing in
                        guard !editing else { return }
                        settings.scrollSpeed = (settings.scrollSpeed * 20).rounded() / 20
                        save(["speedMultiplier": settings.scrollSpeed])
                    }).frame(width: 200).accessibilityLabel("Mouse wheel speed")
                    Text("\(settings.scrollSpeed, specifier: "%.2f")×").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            if value.liveEventTapActive == false {
                LabeledContent("ScrollSplit isn’t changing scrolling yet") {
                    Button("Open ScrollSplit") { Task { await library.launch(.scrollSplit) } }
                }
            }
        } header: {
            Text("Mouse wheel")
        } footer: {
            footnote("Trackpad scrolling is never changed.")
        }
    }

    // MARK: LinkRoutes

    @ViewBuilder
    private func linkSettings(_ value: ToolSettingsSnapshot) -> some View {
        let browsers = value.availableBrowsers ?? []
        Section {
            if value.isDefaultBrowser != true {
                LabeledContent("LinkRoutes isn’t your default browser yet") {
                    Button("Set Up…") { Task { await library.launch(.linkRoutes) } }
                }
            }
            browserPicker("Open everything else in", selection: setting(value.defaultBrowserIdentifier ?? "", key: "defaultBrowserIdentifier"), browsers: browsers)
        } header: {
            Text("Browser")
        }
        if value.stripsTrackingParameters != nil || value.unwrapsRedirects != nil {
            Section {
                if let strips = value.stripsTrackingParameters {
                    Toggle("Remove tracking parameters", isOn: toggle(strips, key: "stripsTrackingParameters"))
                }
                if let unwraps = value.unwrapsRedirects {
                    Toggle("Open the real destination of wrapped links", isOn: toggle(unwraps, key: "unwrapsRedirects"))
                }
            } header: {
                Text("Link Cleaning")
            } footer: {
                footnote("Wrapped links include Outlook Safe Links, which let an organisation scan a link first. Unwrapping skips that.")
            }
        }
        Section {
            ForEach($settings.routeRules) { $rule in
                routeRow($rule, browsers: browsers, sourceRules: value.supportsSourceRules)
            }
            HStack {
                Button("Add Rule", systemImage: "plus") {
                    settings.routeRules.append(BrowserRouteRule(domain: "", browserIdentifier: value.defaultBrowserIdentifier ?? browsers.first?.identifier ?? ""))
                }
                Spacer()
                if settings.hasUnsavedRoutes {
                    Button("Revert") { settings.discardRouteChanges() }
                    Button("Save Rules") { saveRoutes() }.buttonStyle(.borderedProminent).keyboardShortcut("s")
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            footnote(value.supportsSourceRules
                ? "The first rule that matches wins. A rule can also depend on the app a link was clicked in; choose it from the rule’s menu."
                : "The first rule that matches wins.")
        }
    }

    private func browserPicker(_ title: String, selection: Binding<String>, browsers: [AvailableBrowser]) -> some View {
        Picker(title, selection: selection) {
            if selection.wrappedValue.isEmpty { Text("Choose a browser").tag("") }
            ForEach(browsers) { browser in Text(browser.name).tag(browser.identifier) }
            if !selection.wrappedValue.isEmpty, !browsers.contains(where: { $0.identifier == selection.wrappedValue }) {
                Text("Unavailable (\(selection.wrappedValue))").tag(selection.wrappedValue)
            }
        }
    }

    /// One rule on one line: the site, where it goes, and a menu for the rest.
    private func routeRow(_ rule: Binding<BrowserRouteRule>, browsers: [AvailableBrowser], sourceRules: Bool) -> some View {
        let id = rule.wrappedValue.id
        let profiles = browsers.first(where: { $0.identifier == rule.wrappedValue.browserIdentifier })?.profiles ?? []
        let source = rule.wrappedValue.sourceBundleIdentifier
        return HStack(spacing: 8) {
            if let source {
                Text("From \(SourceApps.name(for: source))").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
            }
            TextField("Website", text: rule.websiteText, prompt: Text(source == nil ? "example.com" : "Any website"))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel("Website")
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            browserPicker("Browser", selection: Binding(
                get: { rule.wrappedValue.browserIdentifier },
                set: { rule.wrappedValue.browserIdentifier = $0; rule.wrappedValue.profileDirectory = nil }
            ), browsers: browsers).labelsHidden().frame(width: 150)
            if !profiles.isEmpty || rule.wrappedValue.profileDirectory != nil {
                Picker("Profile", selection: Binding(
                    get: { rule.wrappedValue.profileDirectory ?? "" },
                    set: { rule.wrappedValue.profileDirectory = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default profile").tag("")
                    ForEach(profiles) { profile in Text(profile.name).tag(profile.directory) }
                    if let current = rule.wrappedValue.profileDirectory, !profiles.contains(where: { $0.directory == current }) {
                        Text("Unavailable (\(current))").tag(current)
                    }
                }.labelsHidden().frame(width: 130)
            }
            Menu {
                Toggle("Include Subdomains", isOn: rule.includeSubdomains)
                if sourceRules {
                    Picker("Links From", selection: Binding(
                        get: { rule.wrappedValue.sourceBundleIdentifier ?? "" },
                        set: { rule.wrappedValue.sourceBundleIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Any App").tag("")
                        Divider()
                        ForEach(sourceChoices(current: source)) { choice in Text(choice.name).tag(choice.identifier) }
                    }
                }
                Divider()
                Button("Move Up") { moveRule(id, by: -1) }.disabled(settings.routeRules.first?.id == id)
                Button("Move Down") { moveRule(id, by: 1) }.disabled(settings.routeRules.last?.id == id)
                Divider()
                Button("Remove", role: .destructive) { settings.routeRules.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Rule options")
        }
    }

    private func sourceChoices(current: String?) -> [SourceApp] {
        SourceApps.choices(running: SourceApps.running(), current: current,
                           excluding: [ManagedApp.linkRoutes.bundleIdentifier, Bundle.main.bundleIdentifier ?? ""],
                           nameFor: SourceApps.name(for:))
    }

    private func moveRule(_ id: String, by offset: Int) {
        guard let index = settings.routeRules.firstIndex(where: { $0.id == id }), settings.routeRules.indices.contains(index + offset) else { return }
        settings.routeRules.swapAt(index, index + offset)
    }

    private func saveRoutes() {
        let selectedApp = app
        let sent = settings.routeRules
        Task {
            let prepared = sent.map(\.readyToSave)
            guard let data = try? JSONEncoder().encode(prepared),
                  let rules = try? JSONSerialization.jsonObject(with: data) else { return }
            let accepted = await settings.save(["rules": rules], app: selectedApp, library: library)
            // On success the app returns the rules as it stored them.
            if accepted {
                let stored = library.settingsApp == selectedApp ? settings.snapshot?.rules : nil
                settings.routesSaved(stored ?? prepared, sent: sent)
            }
        }
    }
}
