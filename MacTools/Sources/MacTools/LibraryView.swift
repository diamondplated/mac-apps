import AppKit
import MacToolsCore
import SwiftUI

enum LibrarySelection: Hashable {
    case library, app(ManagedApp)
}

struct LibraryView: View {
    @ObservedObject var library: LibraryModel
    @State private var selection: LibrarySelection? = .library
    @State private var removal: ManagedApp?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Library", systemImage: "square.grid.2x2").tag(LibrarySelection.library)
                ForEach(ManagedApp.Kind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        ForEach(ManagedApp.allCases.filter { $0.kind == kind }) { app in sidebarRow(app) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                if case let .app(app) = current {
                    AppDetailView(library: library, app: app) { removal = app }
                } else {
                    overview
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .animation(.snappy(duration: 0.25), value: bannerText)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup {
                    if current == .library {
                        if library.updateCount > 0 {
                            Button("Update All") { Task { await library.updateAll() } }
                                .buttonStyle(.borderedProminent).disabled(library.isBusy)
                        } else if library.missingApps.count > 1 {
                            Button("Install All") { Task { await library.installMissing() } }
                                .disabled(library.isBusy)
                                .help("Install " + ListFormatter.localizedString(byJoining: library.missingApps.map(\.name)))
                        }
                    }
                }
            }
        }
        .task { await library.refresh() }
        // Another app's Settings item opens its page here: mactools://app/<id>
        .onOpenURL { url in
            if let app = ManagedApp(deepLink: url) { selection = .app(app) }
        }
        .alert("Something went wrong", isPresented: Binding(
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
        } message: { Text("The app will quit first. Its settings and saved files stay on your Mac.") }
    }

    /// Nothing selected (a ⌘-click can deselect the row) still shows the library.
    private var current: LibrarySelection { selection ?? .library }

    private var title: String {
        if case let .app(app) = current { return app.name }
        return "Library"
    }

    private func sidebarRow(_ app: ManagedApp) -> some View {
        let state = library.states[app]
        return Label {
            Text(app.name).foregroundStyle(state?.installedURL == nil ? .secondary : .primary)
        } icon: {
            AppIcon(app: app, image: library.icons[app], size: 18)
                .opacity(state?.installedURL == nil ? 0.55 : 1)
        }
        .badge(state?.isUpdateAvailable == true ? Text("Update") : nil)
        .tag(LibrarySelection.app(app))
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(ManagedApp.Kind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(kind.title).font(.headline).foregroundStyle(.secondary).padding(.leading, 4)
                        let apps = ManagedApp.allCases.filter { $0.kind == kind }
                        VStack(spacing: 0) {
                            ForEach(apps) { app in
                                AppRow(library: library, app: app) { selection = .app(app) }
                                if app != apps.last { Divider().padding(.leading, 74) }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var bannerText: String? {
        library.showsOperation ? library.operation : library.notice
    }

    @ViewBuilder
    private var banner: some View {
        if library.showsOperation, let operation = library.operation {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(operation).font(.callout); Spacer() }
                .modifier(BannerStyle())
        } else if let notice = library.notice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(notice).font(.callout)
                Spacer()
                Button { library.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            .modifier(BannerStyle())
        }
    }
}

private struct BannerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 28).padding(.vertical, 9)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
    }
}

/// One app in the library: what it is, where it stands, and the one thing you can do next.
private struct AppRow: View {
    @ObservedObject var library: LibraryModel
    let app: ManagedApp
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let state = library.states[app]
        HStack(spacing: 14) {
            AppIcon(app: app, image: library.icons[app], size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.medium))
                Text(app.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let status = AppStatus(state) {
                Text(status.label).font(.callout).foregroundStyle(status.isQuiet ? .tertiary : .secondary)
            }
            AppActionButton(library: library, app: app, compact: true)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show \(app.name)", open)
    }
}

/// The short status beside an app. Nothing is shown for an app that is simply installed.
struct AppStatus {
    let label: String
    let isQuiet: Bool

    init?(_ state: ManagedAppState?) {
        guard let state else { return nil }
        if !state.isSupported { label = "Not supported on this Mac"; isQuiet = true }
        else if state.installedURL == nil { label = "Not installed"; isQuiet = true }
        else if state.isUpdateAvailable, let version = state.availableVersion { label = "\(version) available"; isQuiet = false }
        else if state.isRunning { label = "Running"; isQuiet = false }
        else { return nil }
    }
}

/// Install, Update, or Open, with progress shown in place while it works.
struct AppActionButton: View {
    @ObservedObject var library: LibraryModel
    let app: ManagedApp
    var compact = false

    var body: some View {
        if let state = library.states[app] {
            if library.activeApp == app {
                ProgressView().controlSize(.small).frame(minWidth: compact ? 64 : 0)
            } else if !state.isSupported {
                EmptyView()
            } else if state.installedURL != nil && !state.isUpdateAvailable {
                button("Open", prominent: false) { await library.launch(app) }
            } else {
                button(state.installedURL == nil ? "Install" : "Update", prominent: state.installedURL != nil || !compact) {
                    await library.install(app)
                }.disabled(!state.payloadAvailable)
            }
        } else {
            ProgressView().controlSize(.small).frame(minWidth: compact ? 64 : 0)
        }
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool, action: @escaping () async -> Void) -> some View {
        let label = Text(title).fontWeight(.semibold).frame(minWidth: compact ? 44 : 56)
        if prominent {
            Button { Task { await action() } } label: { label }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .controlSize(compact ? .small : .large).disabled(library.isBusy)
        } else {
            Button { Task { await action() } } label: { label }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .controlSize(compact ? .small : .large).disabled(library.isBusy)
        }
    }
}

/// The app's real icon, or a plain symbol tile for an app that ships without one.
struct AppIcon: View {
    let app: ManagedApp
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: app.symbolName).font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: size, height: size)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}
