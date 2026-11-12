import SwiftUI
import AppKit

/// The menu bar. Each item calls the same AppState or EnhancementState method
/// as its toolbar button or key, and shows the shortcut that triggers it.
///
/// Ownership of each shortcut is single, so nothing fires twice:
/// - Command shortcuts (⌘O, ⌘L, ⌘F, ⌘E, ⌘S, ⌘R, ⌘↑, ⌘1, ⌘2, ⌘/) belong to
///   these menu items alone; no toolbar button or key handler registers them.
/// - ⇧P, ⇧X, 0-9 and ⇧G are menu key equivalents too. The browser's key
///   handler skips them while these items are enabled, and the items are
///   disabled whenever the search field, cheat sheet or pairing sheet has
///   the keyboard, so typing in the search field never culls a photo.
/// - ⌫, ⌘Z and ⌘A stay with the window's key monitor, which runs before menu
///   equivalents and steps aside for the search field. Move to Trash shows ⌫
///   for discoverability and is disabled whenever the monitor would pass the
///   key on, so the two never both act on one press.
struct LatentCommands: Commands {
    let state: AppState
    let enhanceState: EnhancementState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { state.openFolder() }
                .keyboardShortcut("o", modifiers: .command)
            OpenRecentMenu(state: state)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export Enhanced Copy") {
                Task { await enhanceState.saveEnhanced() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!state.photoCommandsAvailable
                      || !state.canEnhanceCurrent
                      || !enhanceState.canEnhanceCurrentMedia
                      || enhanceState.isExporting)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Phone Access…") { state.showPairingSheet = true }
                .disabled(state.showPairingSheet)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search This Folder") { state.requestSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(state.folder == nil || state.isLoading || state.isBrowsingArchive)
        }

        CommandGroup(before: .toolbar) {
            ViewMenuItems(state: state)
        }

        CommandMenu("Go") {
            GoMenuItems(state: state)
        }

        CommandMenu("Photo") {
            PhotoMenuItems(state: state)
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { state.showShortcutOverlay = true }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(state.folder == nil || state.showShortcutOverlay)
            Button("Installing Models") { ModelInstallHelp.open() }
        }
    }
}

private struct OpenRecentMenu: View {
    let state: AppState

    var body: some View {
        Menu("Open Recent") {
            ForEach(state.recents.entries, id: \.self) { url in
                Button(url.lastPathComponent) {
                    Task { await state.loadFolder(url) }
                }
                .disabled(state.recents.stale.contains(url))
            }
            if !state.recents.entries.isEmpty {
                Divider()
            }
            Button("Clear Menu") { state.recents.removeAll() }
                .disabled(state.recents.entries.isEmpty)
        }
    }
}

private struct ViewMenuItems: View {
    @Bindable var state: AppState

    var body: some View {
        Group {
            Toggle("as Grid", isOn: Binding(
                get: { state.browseMode == .grid },
                set: { _ in state.browseMode = .grid }
            ))
            .keyboardShortcut("1", modifiers: .command)
            Toggle("as Map", isOn: Binding(
                get: { state.browseMode == .map },
                set: { _ in state.browseMode = .map }
            ))
            .keyboardShortcut("2", modifiers: .command)
        }
        .disabled(state.folder == nil || state.isLoading)

        Divider()

        Button(state.showFolderTree ? "Hide Folder Tree" : "Show Folder Tree") {
            state.showFolderTree.toggle()
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(state.folder == nil || state.isBrowsingArchive)

        Button(state.showEnhancementPanel ? "Hide Enhancements" : "Show Enhancements") {
            state.showEnhancementPanel.toggle()
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!state.canEnhanceCurrent)

        Divider()

        Toggle("Include Subfolders", isOn: Binding(
            get: { state.loadedRecursively },
            set: { _ in state.toggleIncludeSubfolders() }
        ))
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!state.canIncludeSubfolders)

        Picker("Sort By", selection: $state.photoSort) {
            ForEach(FolderSort.allCases) { sort in
                Text(sort.label).tag(sort)
            }
        }
        .disabled(state.imageURLs.isEmpty || state.isLoading)

        Divider()
    }
}

private struct GoMenuItems: View {
    let state: AppState

    var body: some View {
        Button("Next Item") { state.performGo(state.selectNextVisible) }
            .keyboardShortcut("j", modifiers: [])
            .disabled(!state.canCullCurrent)
        Button("Previous Item") { state.performGo(state.selectPreviousVisible) }
            .keyboardShortcut("k", modifiers: [])
            .disabled(!state.canCullCurrent)
        Button("First Item") { state.performGo(state.selectFirstVisible) }
            .disabled(!state.photoCommandsAvailable || state.imageURLs.isEmpty)
        Button("Last Item") { state.performGo(state.selectLastVisible) }
            .keyboardShortcut("g", modifiers: .shift)
            .disabled(!state.photoCommandsAvailable || state.imageURLs.isEmpty)

        Divider()

        Button("Enclosing Folder") { state.goUp() }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!state.canGoUp || state.isLoading)
    }
}

private struct PhotoMenuItems: View {
    let state: AppState

    var body: some View {
        let current = state.currentURL
        Toggle("Pick", isOn: Binding(
            get: { current.map(state.vimKeymap.isPicked) ?? false },
            set: { _ in state.togglePick() }
        ))
        .keyboardShortcut("p", modifiers: .shift)
        .disabled(!state.canCullCurrent)

        Toggle("Reject", isOn: Binding(
            get: { current.map(state.vimKeymap.isRejected) ?? false },
            set: { _ in state.toggleReject() }
        ))
        .keyboardShortcut("x", modifiers: .shift)
        .disabled(!state.canCullCurrent)

        Menu("Label") {
            let active = current.map(state.vimKeymap.colorLabel(for:)) ?? 0
            ForEach(ColorLabel.all, id: \.self) { label in
                Toggle(isOn: Binding(
                    get: { active == label },
                    // Sets, never toggles: the menu owns the digit keys, and
                    // pressing 3 on a photo labelled 3 has always kept it.
                    set: { _ in state.setColorLabel(label) }
                )) {
                    Label { Text(ColorLabel.name(label)) } icon: { ColorLabel.menuIcon(label) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(label))), modifiers: [])
            }
            Divider()
            Button("No Label") { state.setColorLabel(0) }
                .keyboardShortcut("0", modifiers: [])
        }
        .disabled(!state.canCullCurrent)

        Divider()

        Button("Reveal in Finder") { state.revealCurrentInFinder() }
            .disabled(current == nil || !state.photoCommandsAvailable)
        Button("Move to Trash") { state.trashCurrentImage() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!state.canCullCurrent || state.isBrowsingArchive)
    }
}
