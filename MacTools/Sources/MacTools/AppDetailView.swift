import AppKit
import MacToolsCore
import SwiftUI

/// Everything about one app on one page: what it is, its settings, the access it needs,
/// and where it lives.
struct AppDetailView: View {
    @ObservedObject var library: LibraryModel
    let app: ManagedApp
    let uninstall: () -> Void

    private var state: ManagedAppState? { library.states[app] }
    private var isInstalled: Bool { state?.installedURL != nil }
    private var showsSettings: Bool { isInstalled && app.supportsSettingsBridge }

    var body: some View {
        Form {
            // The routine states already show in the header. Only a problem gets a row.
            if let state, !state.isSupported || !state.payloadAvailable {
                Section {
                    Label(state.detail, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            if showsSettings {
                ToolSettingsView(library: library, app: app)
            } else {
                Section(isInstalled ? "How it works" : "Getting started") {
                    Text(app.onboarding).foregroundStyle(.secondary)
                }
            }
            about
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The header stays put while the settings scroll beneath it.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // Reload when the app changes, is installed or updated, or an operation finishes.
        .task(id: SettingsKey(app: app, version: state?.installedVersion, busy: library.isBusy)) { await loadSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings: pick up a permission that was just granted.
            Task { await loadSettings() }
        }
    }

    private struct SettingsKey: Hashable {
        let app: ManagedApp
        let version: String?
        let busy: Bool
    }

    private func loadSettings() async {
        guard showsSettings, !library.isBusy else { return }
        library.settingsApp = app
        await library.toolSettings.load(app, library: library)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            AppIcon(app: app, image: library.icons[app], size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title.weight(.semibold))
                // No vertical fixedSize here: in a row it reports the height of the text
                // wrapped one word per line, which makes the window's content taller than
                // the window and slides everything up under the title bar.
                Text(app.summary).foregroundStyle(.secondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 16)
            if let status = AppStatus(state) {
                Text(status.label).font(.callout).foregroundStyle(.secondary)
            }
            AppActionButton(library: library, app: app)
            if isInstalled {
                Menu {
                    if state?.isUpdateAvailable == true {
                        Button("Open Current Version") { Task { await library.launch(app) } }
                    }
                    Button("Show in Finder") { library.reveal(app) }
                    if state?.isRunning == true {
                        Button("Quit \(app.name)") { Task { await library.quit(app) } }
                    }
                    Divider()
                    Button("Uninstall…", role: .destructive, action: uninstall)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(library.isBusy).help("More")
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
    }

    private var about: some View {
        Section("About") {
            if let installed = state?.installedVersion {
                LabeledContent("Version", value: installed)
                if state?.isUpdateAvailable == true, let available = state?.availableVersion {
                    LabeledContent("Included with Mac Tools", value: available)
                }
            } else if let available = state?.availableVersion {
                LabeledContent("Version", value: available)
            }
            LabeledContent("Requires", value: app.requirement)
            if let url = state?.installedURL {
                LabeledContent("Location") {
                    Text(url.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}
