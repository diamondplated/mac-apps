import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var state: AppState
    /// Owned by the app so File > Export Enhanced Copy remains available
    /// while the optional side panel is closed.
    @Bindable var enhanceState: EnhancementState
    /// Window-level arrow-key monitor. Lives at the ContentView level so it
    /// installs as soon as the app launches, not only after a folder opens —
    /// otherwise arrow keys do nothing on the first folder you load (the
    /// monitor's host view is still in empty state).
    @State private var keyMonitor = NavigationKeyMonitor()
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if state.folder == nil && state.loadPhase == nil {
                StartView(state: state, isDropTargeted: isDropTargeted)
            } else {
                BrowserView(state: state, enhanceState: enhanceState)
            }
        }
        // The displayed pairing code dies with the sheet, so a photo of the
        // screen taken after it closes is worth nothing.
        .sheet(isPresented: $state.showPairingSheet, onDismiss: {
            Task { await state.phoneAccess.closePairingSheet() }
        }) {
            PairingSheet(controller: state.phoneAccess, ui: state.phoneAccess.ui)
        }
        .onAppear { keyMonitor.install(state: state) }
        .onDisappear {
            // Closing the window can destroy this view (and therefore its
            // termination subscription) before the process itself exits. The
            // app owns `state`, so a failed flush remains recoverable after the
            // window closes; bring the window back to surface the error.
            let didFlush = state.flushCullingState()
            keyMonitor.uninstall()
            if !didFlush {
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeKey })?
                        .makeKeyAndOrderFront(nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.flushCullingState()
            state.cleanUpArchiveOnTermination()
        }
        // Right-click in Finder → "Open With → Latent" delivers the URL
        // here. Works for both folders (open as a folder) and individual
        // images (open the parent folder, jump to the clicked image).
        .onOpenURL { url in
            Task { await state.openURL(url) }
        }
        // Drag a folder, archive, or image from Finder onto the Latent
        // window → open it. Same routing as Open With. Works both from the
        // start screen and while a folder is already loaded (drop replaces
        // the current view).
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            Task { await state.openURL(first) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert(
            "Latent couldn’t complete that action",
            isPresented: Binding(
                get: { state.userError != nil },
                set: { if !$0 { state.clearUserError() } }
            )
        ) {
            if state.canUseUnverifiedCullingState {
                Button("Use Saved Culls") { state.useUnverifiedCullingState() }
                Button("Keep Disabled", role: .cancel) { state.clearUserError() }
            } else {
                Button("OK", role: .cancel) { state.clearUserError() }
            }
        } message: {
            Text(state.userError ?? "")
        }
    }
}

/// The window before any folder is open: the app's mark, one Open button,
/// and the recent folders as a grouped list.
struct StartView: View {
    @Bindable var state: AppState
    let isDropTargeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Theme.Spacing.section) {
                    hero
                    if !state.recents.entries.isEmpty {
                        recentsList
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)
                .padding(.vertical, 56)
                // Centred in the window when it fits; scrolls when it doesn't.
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            // Drop affordance: a quiet accent outline while a folder hovers.
            Theme.shape(Theme.Radius.panel)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(Theme.Spacing.regular)
                .opacity(isDropTargeted ? 1 : 0)
                .latentAnimation(isDropTargeted, reduceMotion: reduceMotion, duration: Theme.Motion.quick)
                .allowsHitTesting(false)
        }
        .onAppear {
            // Re-check existence in the background each time the start
            // screen surfaces (folders may have moved while one was open).
            Task { await state.recents.refreshExistence() }
        }
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.regular) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.tight) {
                Text("Latent")
                    .font(.largeTitle.weight(.semibold))
                Text("Open a folder or archive of photos.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Button {
                state.openFolder()
            } label: {
                Text("Open…")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, Theme.Spacing.small)
            Text("Or drop a folder onto this window.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.headline)
                Spacer()
                Button("Clear") { state.recents.removeAll() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .padding(.horizontal, Theme.Spacing.tight)

            VStack(spacing: 0) {
                let entries = state.recents.entries
                ForEach(Array(entries.enumerated()), id: \.element) { index, url in
                    RecentRow(
                        url: url,
                        isStale: state.recents.stale.contains(url),
                        onOpen: { Task { await state.loadFolder(url) } },
                        onRemove: { state.recents.remove(url) }
                    )
                    if index < entries.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(Theme.shape(Theme.Radius.card))
            .overlay(Theme.shape(Theme.Radius.card).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// One row in the start screen's recent list. Click anywhere to open; the
/// remove button appears on hover.
struct RecentRow: View {
    let url: URL
    let isStale: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            Image(systemName: isStale ? "questionmark.folder" : "folder.fill")
                .font(.title3)
                .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.body)
                    .foregroundStyle(isStale ? .secondary : .primary)
                    .lineLimit(1)
                Text(isStale ? "Folder not found" : prettyParentPath(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.small)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from Recent")
            .accessibilityLabel("Remove \(url.lastPathComponent) from Recent")
            .opacity(hovered ? 1 : 0)
            .latentAnimation(hovered, reduceMotion: reduceMotion, duration: Theme.Motion.quick)
        }
        .padding(.horizontal, Theme.Spacing.regular)
        .padding(.vertical, Theme.Spacing.small)
        .contentShape(Rectangle())
        .background(hovered && !isStale ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovered = $0 }
        .onTapGesture {
            // A stale entry would only confuse the loader with a missing path.
            guard !isStale else { return }
            onOpen()
        }
        .help(isStale ? "Folder no longer exists" : url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func prettyParentPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home) { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
