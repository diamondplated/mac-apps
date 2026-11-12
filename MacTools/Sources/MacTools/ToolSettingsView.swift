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
    @State private var confirmingStopRouting = false

    var body: some View {
        if let snapshot = settings.snapshot, snapshot.app == app.rawValue {
            switch app {
            case .dockPeek: dockSettings(snapshot)
            case .screenWren:
                captureSettings(snapshot)
                selectionSettings(snapshot)
                shortcutSettings(snapshot)
            case .scrollSplit:
                scrollSettings(snapshot)
                keyboardSettings(snapshot)
                if snapshot.shortcuts?.isEmpty == false { shortcutSettings(snapshot) }
            case .linkRoutes:
                linkSettings(snapshot)
                fileSettings(snapshot)
            case .stayLit: stayLitSettings(snapshot)
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
        case .stayLit: return [accessibility]
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
        if let restores = value.restoresWindowLayouts {
            Section {
                Toggle("Put windows back when displays change", isOn: toggle(restores, key: "restoresWindowLayouts"))
            } header: {
                Text("Window Layouts")
            } footer: {
                footnote("DockPeek remembers where windows were for each monitor setup. Save or restore a layout by hand from its menu bar menu.")
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

    @ViewBuilder
    private func scrollSettings(_ value: ToolSettingsSnapshot) -> some View {
        Section {
            // With the mouse fixes present, this one switch governs all of them.
            Toggle(value.hasMouseFixes ? "Customize the mouse" : "Change mouse wheel scrolling",
                   isOn: toggle(value.enabled ?? false, key: "enabled"))
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
            if let smooth = value.smoothScrolling {
                Toggle("Smooth scrolling", isOn: toggle(smooth, key: "smoothScrolling"))
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
        if value.sideButtonsNavigate != nil || value.mouseAccelerationOff != nil {
            Section {
                if let navigate = value.sideButtonsNavigate {
                    Toggle("Side buttons go back and forward", isOn: toggle(navigate, key: "sideButtonsNavigate"))
                }
                if let linear = value.mouseAccelerationOff {
                    Toggle("Turn off pointer acceleration for mice", isOn: toggle(linear, key: "mouseAccelerationOff"))
                        .disabled(value.mouseAccelerationAvailable == false)
                }
            } header: {
                Text("Buttons and Pointer")
            } footer: {
                footnote(value.mouseAccelerationAvailable == false
                    ? "Pointer acceleration can’t be changed per device on this Mac."
                    : "The trackpad keeps its normal feel. These start off because they change how the mouse behaves.")
            }
        }
    }

    @ViewBuilder
    private func keyboardSettings(_ value: ToolSettingsSnapshot) -> some View {
        if value.hasKeyboardOverrides {
            Section {
                if let hold = value.holdToQuit {
                    Toggle("Hold ⌘Q to quit", isOn: toggle(hold, key: "holdToQuit"))
                }
                if let hyper = value.capsLockIsHyper {
                    Toggle("Caps Lock is a Hyper key (⌃⌥⇧⌘)", isOn: toggle(hyper, key: "capsLockIsHyper"))
                        .disabled(value.capsLockRemapAvailable == false)
                    if let tap = value.capsLockTapIsEscape {
                        Toggle("Tap Caps Lock for Escape", isOn: toggle(tap, key: "capsLockTapIsEscape"))
                            .disabled(!(settings.pending["capsLockIsHyper"] as? Bool ?? hyper))
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                footnote(value.capsLockRemapAvailable == false
                    ? "Caps Lock can’t be remapped on this Mac."
                    : "While Caps Lock is a Hyper key it no longer locks capitals.")
            }
        }
    }

    // MARK: StayLit

    @ViewBuilder
    private func stayLitSettings(_ value: ToolSettingsSnapshot) -> some View {
        let apps = value.keepAwakeApps ?? []
        Section {
            Toggle("Keep the Mac awake", isOn: toggle(value.keepAwake ?? false, key: "keepAwake"))
            Toggle("Keep the display on too", isOn: toggle(value.keepsDisplayAwake ?? false, key: "keepsDisplayAwake"))
            if let reason = value.awakeReason {
                LabeledContent("Right now", value: reason)
            }
        } header: {
            Text("Keep Awake")
        } footer: {
            footnote("Use StayLit’s menu bar menu to keep the Mac awake for a set time. On battery below 20 percent it lets the Mac sleep.")
        }
        Section {
            ForEach(apps, id: \.self) { identifier in
                LabeledContent(SourceApps.name(for: identifier)) {
                    Button("Remove \(SourceApps.name(for: identifier))", systemImage: "minus.circle", role: .destructive) {
                        editAwakeApps(from: apps) { $0.filter { $0 != identifier } }
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Menu("Add App") {
                let choices = SourceApps.choices(running: SourceApps.running(), current: nil,
                                                 excluding: Set(apps).union([ManagedApp.stayLit.bundleIdentifier, Bundle.main.bundleIdentifier ?? ""]),
                                                 nameFor: SourceApps.name(for:))
                if choices.isEmpty { Text("No other apps are open") }
                ForEach(choices) { choice in
                    Button(choice.name) { editAwakeApps(from: apps) { $0 + [choice.identifier] } }
                }
            }.fixedSize()
        } header: {
            Text("Awake While These Apps Run")
        } footer: {
            footnote("Open an app to add it here.")
        }
        Section {
            Toggle("Brightness keys control an external display", isOn: toggle(value.brightnessKeysControlDisplays ?? false, key: "brightnessKeysControlDisplays"))
            Toggle("Volume keys control an external display", isOn: toggle(value.volumeKeysControlDisplays ?? false, key: "volumeKeysControlDisplays"))
            ForEach(value.externalDisplays ?? []) { display in
                LabeledContent(display.name) {
                    Text(display.controllable ? "Can be controlled" : "Doesn’t accept control").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("External Displays")
        } footer: {
            footnote((value.externalDisplays ?? []).isEmpty
                ? "No external display is connected. The keys work on the display the pointer is on; the built-in display is left to macOS."
                : "The keys work on the display the pointer is on; the built-in display is left to macOS.")
        }
    }

    /// Changes the list starting from whatever is saved when this edit's turn comes.
    private func editAwakeApps(from shown: [String], _ change: @escaping ([String]) -> [String]) {
        let selectedApp = app
        Task {
            await settings.save(app: selectedApp, library: library) { latest in
                ["keepAwakeApps": change(latest?.keepAwakeApps ?? shown)]
            }
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

    @ViewBuilder
    private func fileSettings(_ value: ToolSettingsSnapshot) -> some View {
        if value.fileRules != nil {
            Section {
                ForEach($settings.fileRules) { $rule in fileRow($rule) }
                HStack {
                    Button("Add File Rule", systemImage: "plus") {
                        settings.fileRules.append(FileRouteRule(fileExtension: "", applicationIdentifier: ""))
                    }
                    Spacer()
                    if settings.hasUnsavedFileRules {
                        Button("Revert") { settings.discardFileRuleChanges() }
                        Button("Save File Rules") { saveFileRules() }.buttonStyle(.borderedProminent)
                    }
                }
                if let taken = value.takenOverExtensions, !taken.isEmpty {
                    LabeledContent("LinkRoutes opens \(ListFormatter.localizedString(byJoining: taken.map { "." + $0 })) files first") {
                        Button("Stop Routing Files…") { confirmingStopRouting = true }
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                footnote("The first rule that matches wins. LinkRoutes becomes the default app for a file type only while that type has a rule; files that match no rule open in the app that was the default before.")
            }
            .confirmationDialog("Stop routing files?", isPresented: $confirmingStopRouting, titleVisibility: .visible) {
                Button("Stop Routing Files") { save(["stopRoutingFiles": true]) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every file type goes back to the app that opened it before, and the file rules are removed.")
            }
        }
    }

    /// One file rule on one line: the type, where, and what opens it.
    private func fileRow(_ rule: Binding<FileRouteRule>) -> some View {
        let id = rule.wrappedValue.id
        let ext = rule.wrappedValue.readyToSave.fileExtension
        let current = rule.wrappedValue.applicationIdentifier
        let apps = SourceApps.choices(running: FileApps.able(toOpen: ext), current: current,
                                      excluding: [ManagedApp.linkRoutes.bundleIdentifier], nameFor: SourceApps.name(for:))
        return HStack(spacing: 8) {
            TextField("Type", text: rule.fileExtension, prompt: Text("md")).textFieldStyle(.roundedBorder).labelsHidden()
                .frame(width: 64).accessibilityLabel("File extension")
            Text("in").foregroundStyle(.secondary)
            Text(FileApps.display(folder: rule.wrappedValue.folder)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(rule.wrappedValue.folder == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Picker("Open With", selection: rule.applicationIdentifier) {
                if current.isEmpty { Text("Choose an app").tag("") }
                ForEach(apps) { app in Text(app.name).tag(app.identifier) }
            }.labelsHidden().frame(width: 170)
            Menu {
                Button("Choose Folder…") { chooseFolder(for: rule) }
                Button("Any Folder") { rule.wrappedValue.folder = nil }.disabled(rule.wrappedValue.folder == nil)
                Divider()
                Button("Move Up") { moveFileRule(id, by: -1) }.disabled(settings.fileRules.first?.id == id)
                Button("Move Down") { moveFileRule(id, by: 1) }.disabled(settings.fileRules.last?.id == id)
                Divider()
                Button("Remove", role: .destructive) { settings.fileRules.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Rule options")
        }
    }

    private func chooseFolder(for rule: Binding<FileRouteRule>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Files inside this folder follow the rule."
        if panel.runModal() == .OK, let url = panel.url { rule.wrappedValue.folder = url.path }
    }

    private func moveFileRule(_ id: String, by offset: Int) {
        guard let index = settings.fileRules.firstIndex(where: { $0.id == id }), settings.fileRules.indices.contains(index + offset) else { return }
        settings.fileRules.swapAt(index, index + offset)
    }

    private func saveFileRules() {
        let selectedApp = app
        let sent = settings.fileRules
        Task {
            let prepared = sent.map(\.readyToSave)
            guard let data = try? JSONEncoder().encode(prepared),
                  let rules = try? JSONSerialization.jsonObject(with: data) else { return }
            let accepted = await settings.save(["fileRules": rules], app: selectedApp, library: library)
            if accepted {
                let stored = library.settingsApp == selectedApp ? settings.snapshot?.fileRules : nil
                settings.fileRulesSaved(stored ?? prepared, sent: sent)
            }
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
