import AppKit
import MacToolsCore
import SwiftUI

private enum LibrarySelection: Hashable {
    case all, installed, settings, updates, app(ManagedApp), utility(UtilityTool)
}

private enum UtilityTool: String, CaseIterable, Identifiable {
    case permissions, startup, sleep, storage, resources, network
    var id: String { rawValue }
    var title: String {
        switch self {
        case .permissions: "Permission Doctor"
        case .startup: "Startup Detective"
        case .sleep: "SleepPeek"
        case .storage: "SpaceWatch"
        case .resources: "HogWatch"
        case .network: "NetPeek"
        }
    }
    var symbol: String {
        switch self {
        case .permissions: "checkmark.shield"
        case .startup: "sunrise"
        case .sleep: "moon.zzz"
        case .storage: "externaldrive"
        case .resources: "chart.xyaxis.line"
        case .network: "network"
        }
    }
    var summary: String {
        switch self {
        case .permissions: "Get your tools working with the right access."
        case .startup: "Find out what starts with your Mac."
        case .sleep: "See what’s keeping your Mac awake."
        case .storage: "Find large files and see what’s growing."
        case .resources: "Spot apps that keep your Mac busy."
        case .network: "Find where a connection breaks down."
        }
    }
    var color: Color {
        switch self {
        case .permissions: .indigo
        case .startup: .orange
        case .sleep: .purple
        case .storage: .teal
        case .resources: .pink
        case .network: .blue
        }
    }
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
                    Label("Overview", systemImage: "square.grid.2x2")
                        .badge(ManagedApp.allCases.count + UtilityTool.allCases.count).tag(LibrarySelection.all)
                    Label("Installed", systemImage: "checkmark.circle")
                        .badge(library.installedCount).tag(LibrarySelection.installed)
                }
                Section("Your Apps") {
                    ForEach(ManagedApp.allCases) { app in
                        Label(app.name, systemImage: app.symbolName).tag(LibrarySelection.app(app))
                    }
                }
                Section("Utilities") {
                    ForEach(UtilityTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(LibrarySelection.utility(tool))
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
                        Text("Everyday tools, together").font(.caption).foregroundStyle(.secondary)
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
                    } else if case let .utility(tool) = selection { utilityPage(tool) }
                    else if case let .app(app) = selection { detail(app) }
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
        case .utility(let tool): tool.title
        case .installed: "Installed"
        case .settings: "Tool Settings"
        case .updates: "Mac Tools Updates"
        default: "Overview"
        }
    }

    private var visibleApps: [ManagedApp] {
        if selection == .installed { return ManagedApp.allCases.filter { library.states[$0]?.installedURL != nil } }
        return ManagedApp.allCases
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selection == .installed ? "Ready when you are." : "Small tools. A calmer Mac.")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                Text("Capture, navigate, and make sense of your Mac. Your everyday tools, in one place.")
                    .font(.body).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                metric("IN YOUR COLLECTION", value: "\(ManagedApp.allCases.count + UtilityTool.allCases.count)", symbol: "square.grid.2x2")
                Divider().frame(height: 40).padding(.horizontal, 24)
                metric("INSTALLED", value: "\(library.installedCount)", symbol: "checkmark.circle")
                Divider().frame(height: 40).padding(.horizontal, 24)
                metric("BUILT IN", value: "\(UtilityTool.allCases.count)", symbol: "sparkles")
                Spacer()
                if library.updateCount > 0 {
                    Button("Update All (\(library.updateCount))") { Task { await library.updateAll() } }
                        .buttonStyle(.borderedProminent).disabled(library.isBusy)
                }
            }.padding(22).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            if visibleApps.isEmpty {
                ContentUnavailableView("Your apps will appear here", systemImage: "tray", description: Text("Choose Overview to install your first tool."))
            } else {
                Text("Everyday apps").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                    ForEach(visibleApps) { app in appCard(app) }
                }
            }
            if selection != .installed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Know your Mac").font(.title3.bold())
                    Text("Six useful places to start when something feels off.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(UtilityTool.allCases) { tool in utilityCard(tool) }
                }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(features(app), id: \.self) { feature in
                    Text(feature).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
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
                Text(onboarding(app))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if app == .dockPeek || app == .scrollSplit {
                        Button("Accessibility Settings") { library.openSettings("com.apple.preference.security?Privacy_Accessibility") }
                    }
                    if app == .dockPeek || app == .screenWren {
                        Button("Screen Recording Settings") { library.openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
                    }
                    if app == .scrollSplit {
                        Button("Input Monitoring") { library.openSettings("com.apple.preference.security?Privacy_ListenEvent") }
                    }
                    Button("Check Setup") { selection = .utility(.permissions) }
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
                    .background(LinearGradient(colors: appColors(app), startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.23))
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
        switch app {
        case .dockPeek: ["Live previews", "Window switching", "Browser tabs"]
        case .screenWren: ["Region & window capture", "Markup", "Text recognition"]
        case .scrollSplit: ["Mouse direction", "Wheel speed", "Trackpad preserved"]
        case .linkRoutes: ["Domain rules", "Browser profiles", "Link preview"]
        }
    }

    private func appColors(_ app: ManagedApp) -> [Color] {
        switch app {
        case .dockPeek: [.indigo, .blue]
        case .screenWren: [.teal, .cyan]
        case .scrollSplit: [.teal, .green]
        case .linkRoutes: [.indigo, .purple]
        }
    }

    private func onboarding(_ app: ManagedApp) -> String {
        switch app {
        case .dockPeek: "Grant Accessibility and Screen Recording, then hover an app in your Dock. Use DockPeek’s menu bar icon for its permission status."
        case .screenWren: "Grant Screen Recording, then capture and annotate from the menu bar. Set shortcuts and launch at login in Tool Settings."
        case .scrollSplit: "Open ScrollSplit to enable scrolling and grant its requested access. Set wheel direction and speed in Tool Settings. Smooth scrolling devices pass through unchanged."
        case .linkRoutes: "Choose browsers and domain rules in Tool Settings. Open LinkRoutes to make it your default link handler when you’re ready."
        }
    }

    private func utilityCard(_ tool: UtilityTool) -> some View {
        Button { selection = .utility(tool) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: tool.symbol).font(.system(size: 23, weight: .medium))
                        .foregroundStyle(tool.color).frame(width: 48, height: 48)
                        .background(tool.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tool.title).font(.headline).foregroundStyle(.primary)
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Included in Mac Tools").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(22).frame(maxWidth: .infinity, minHeight: 192, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.quaternary, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("Open \(tool.title). \(tool.summary)")
    }

    @ViewBuilder private func utilityPage(_ tool: UtilityTool) -> some View {
        switch tool {
        case .permissions: PermissionDoctorView(library: library)
        case .startup: StartupDetectiveView()
        case .sleep: SleepPeekView()
        case .storage: SpaceWatchView()
        case .resources: HogWatchView()
        case .network: NetPeekView()
        }
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
