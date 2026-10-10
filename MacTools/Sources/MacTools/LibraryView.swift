import AppKit
import MacToolsCore
import SwiftUI

private enum LibrarySelection: Hashable {
    case all, installed, settings, updates, app(ManagedApp)
}

struct LibraryView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var updater: UpdateController
    @State private var selection: LibrarySelection? = .all
    @State private var removal: ManagedApp?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("All Apps", systemImage: "square.grid.2x2")
                        .badge(ManagedApp.allCases.count).tag(LibrarySelection.all)
                    Label("Installed", systemImage: "checkmark.circle")
                        .badge(library.installedCount).tag(LibrarySelection.installed)
                }
                Section("Your Apps") {
                    ForEach(ManagedApp.allCases) { app in
                        Label(app.name, systemImage: app.symbolName).tag(LibrarySelection.app(app))
                    }
                }
                Section {
                    Label("Tool Settings", systemImage: "slider.horizontal.3").tag(LibrarySelection.settings)
                    Label("Mac Tools Updates", systemImage: "arrow.triangle.2.circlepath").tag(LibrarySelection.updates)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title3).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac Tools").font(.headline)
                        Text("A small collection for your Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(16)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if selection == .settings {
                        ToolSettingsView(library: library)
                    } else if selection == .updates {
                        ManagerUpdatesView(updater: updater)
                    } else if case let .app(app) = selection { detail(app) }
                    else { collection }
                    activity
                }
                .padding(32)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(title)
            .toolbar {
                ToolbarItem {
                    Button { Task { await library.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.help("Refresh installed apps (⌘R)").disabled(library.isBusy)
                }
            }
        }
        .task { await library.refresh() }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { library.error != nil }, set: { if !$0 { library.error = nil } }
        )) { Button("OK", role: .cancel) { library.error = nil } }
        message: { Text(library.error ?? "") }
        .confirmationDialog("Move \(removal?.name ?? "this app") to the Trash?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible) {
            if let app = removal {
                Button("Move to Trash", role: .destructive) { removal = nil; Task { await library.uninstall(app) } }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("The app will quit first. Its settings and saved files will stay on your Mac.") }
    }

    private var title: String {
        switch selection {
        case .app(let app): app.name
        case .installed: "Installed"
        case .settings: "Tool Settings"
        case .updates: "Mac Tools Updates"
        default: "All Apps"
        }
    }

    private var visibleApps: [ManagedApp] {
        if selection == .installed { return ManagedApp.allCases.filter { library.states[$0]?.installedURL != nil } }
        return ManagedApp.allCases
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selection == .installed ? "Ready when you are." : "Make yourself at home.")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                Text("Window previews and thoughtful screenshots. Keep your everyday tools together.")
                    .font(.body).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                metric("IN YOUR COLLECTION", value: "\(ManagedApp.allCases.count)", symbol: "square.grid.2x2")
                Divider().frame(height: 40).padding(.horizontal, 24)
                metric("INSTALLED", value: "\(library.installedCount)", symbol: "checkmark.circle")
                Spacer()
                if library.updateCount > 0 {
                    Button("Update All (\(library.updateCount))") { Task { await library.updateAll() } }
                        .buttonStyle(.borderedProminent).disabled(library.isBusy)
                }
            }.padding(22).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            if visibleApps.isEmpty {
                ContentUnavailableView("Your apps will appear here", systemImage: "tray", description: Text("Choose All Apps to install your first tool."))
            } else {
                ForEach(visibleApps) { app in appCard(app) }
            }
            installDestination
            if library.installedCount < ManagedApp.allCases.count && ManagedApp.allCases.contains(where: {
                guard let state = library.states[$0] else { return false }
                return state.installedURL == nil && state.payloadAvailable && state.isSupported
            }) {
                Button("Install Missing Apps") { Task { await library.installMissing() } }
                    .buttonStyle(.bordered).disabled(library.isBusy)
            }
            Text("Apps are included with this copy of Mac Tools. Get a newer Mac Tools release to receive new app versions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
            Label(value, systemImage: symbol).font(.system(size: 24, weight: .semibold, design: .rounded))
        }
    }

    private func appCard(_ app: ManagedApp) -> some View {
        let state = library.states[app]
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                appIcon(app, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { selection = .app(app) } label: { Text(app.name).font(.title2.bold()) }
                            .buttonStyle(.plain)
                        Spacer()
                        status(state)
                    }
                    Text(app.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                ForEach(features(app), id: \.self) { feature in
                    Text(feature).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(versionDescription(state)).font(.caption).foregroundStyle(.secondary)
                    if let state, !state.isSupported || !state.payloadAvailable || !state.detail.isEmpty {
                        Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Button("Details") { selection = .app(app) }.buttonStyle(.borderless)
                primaryAction(app)
            }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func detail(_ app: ManagedApp) -> some View {
        let state = library.states[app]
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 22) {
                appIcon(app, size: 90)
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.name).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(app.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    status(state)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                primaryAction(app)
                if state?.isUpdateAvailable == true {
                    Button("Open Current Version") { Task { await library.launch(app) } }
                        .buttonStyle(.bordered).disabled(library.isBusy)
                }
                if state?.installedURL != nil {
                    Button("Settings", systemImage: "slider.horizontal.3") {
                        library.settingsApp = app
                        selection = .settings
                    }.buttonStyle(.bordered)
                    Button("Show in Finder") { library.reveal(app) }.buttonStyle(.bordered)
                    if state?.isRunning == true {
                        Button("Quit") { Task { await library.quit(app) } }.buttonStyle(.bordered).disabled(library.isBusy)
                    }
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    infoRow("Installed version", value: state?.installedVersion ?? "Not installed")
                    infoRow("Included version", value: state?.availableVersion ?? "Unavailable")
                    infoRow("Requires", value: "macOS \(app.minimumOSMajor) or later")
                    if let url = state?.installedURL {
                        infoRow("Location", value: url.path).textSelection(.enabled)
                    }
                    if let state, !state.detail.isEmpty {
                        Divider()
                        Text(state.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state?.installedURL == nil { installDestination }
            VStack(alignment: .leading, spacing: 12) {
                Text("Make it yours").font(.title3.bold())
                Text(app == .dockPeek
                     ? "Grant Accessibility and Screen Recording, then hover an app in your Dock. Use DockPeek’s menu bar icon for its permission status."
                     : "Grant Screen Recording, then use ScreenWren’s menu bar icon to capture and annotate. Set shortcuts and launch at login in its Settings.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if app == .dockPeek {
                        Button("Accessibility Settings") { library.openSettings("com.apple.preference.security?Privacy_Accessibility") }
                    }
                    Button("Screen Recording Settings") { library.openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
                    Button("Login Items") { library.openSettings("com.apple.LoginItems-Settings.extension") }
                }.buttonStyle(.bordered)
            }
            if state?.installedURL != nil {
                Divider()
                HStack {
                    Text("Remove the app and keep your settings.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Uninstall…", role: .destructive) { removal = app }
                        .disabled(library.isBusy)
                }
            }
        }
    }

    private var installDestination: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install new apps for").font(.callout.weight(.medium))
                Text("Updates stay in the app’s current location.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Install new apps for", selection: $library.scope) {
                ForEach(InstallScope.allCases) { scope in Text(scope == .user ? "Just Me" : "All Users").tag(scope) }
            }.labelsHidden().pickerStyle(.segmented).frame(width: 230).disabled(library.isBusy)
        }
    }

    @ViewBuilder
    private func primaryAction(_ app: ManagedApp) -> some View {
        if let state = library.states[app] {
            if !state.isSupported {
                Text("Requires macOS \(app.minimumOSMajor)").font(.caption).foregroundStyle(.secondary)
            } else if state.installedURL != nil && !state.isUpdateAvailable {
                Button("Open", systemImage: "arrow.up.forward.app") { Task { await library.launch(app) } }
                    .buttonStyle(.borderedProminent).disabled(library.isBusy)
            } else {
                Button(state.installedURL == nil ? "Install" : "Update", systemImage: "arrow.down.circle") {
                    Task { await library.install(app) }
                }.buttonStyle(.borderedProminent).disabled(library.isBusy || !state.payloadAvailable)
            }
        } else { ProgressView().controlSize(.small) }
    }

    private func status(_ state: ManagedAppState?) -> some View {
        let label = state == nil ? "Checking" : state?.isUpdateAvailable == true ? "Update available" : state?.isRunning == true ? "Running" : state?.installedURL != nil ? "Installed" : "Not installed"
        let color: Color = state?.isUpdateAvailable == true ? .orange : state?.installedURL != nil ? .green : .secondary
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(color)
        }.padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule())
    }

    private func appIcon(_ app: ManagedApp, size: CGFloat) -> some View {
        let payload = Bundle.main.resourceURL?.appendingPathComponent("Applications").appendingPathComponent(app.payloadFilename)
        let url = library.states[app]?.installedURL ?? payload
        return Group {
            if let url, FileManager.default.fileExists(atPath: url.path), app == .screenWren {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            } else {
                Image(systemName: app.symbolName).font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white).frame(width: size, height: size)
                    .background(LinearGradient(colors: app == .dockPeek ? [.indigo, .blue] : [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.23))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }

    private func features(_ app: ManagedApp) -> [String] {
        app == .dockPeek ? ["Live previews", "Window switching", "Browser tabs"] : ["Region & window capture", "Markup", "Text recognition"]
    }

    private func versionDescription(_ state: ManagedAppState?) -> String {
        guard let state else { return "Checking your Mac…" }
        if let version = state.installedVersion {
            return "Installed \(version)" + (state.isUpdateAvailable ? "  ·  Included \(state.availableVersion ?? "update")" : "")
        }
        return state.availableVersion.map { "Version \($0) included" } ?? "Installer unavailable in this copy"
    }

    @ViewBuilder
    private var activity: some View {
        if let operation = library.operation {
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text(operation).font(.callout) }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(operation)
        } else if let notice = library.notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
        }
    }
}
