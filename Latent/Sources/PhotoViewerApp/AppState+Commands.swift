import Foundation
import AppKit
import PhotoViewerCore

// What the menu bar asks of AppState. Every command here is also reachable by
// keyboard or toolbar; both paths call the same method so the behaviour, and
// the guards in front of it, cannot drift apart.

@MainActor
extension AppState {
    /// True when the window's normal photo commands should be live: a folder
    /// is open and settled, and nothing modal (search field, cheat sheet,
    /// pairing sheet, error alert) owns the keyboard. Disabled menu items do
    /// not claim their key equivalents, which keeps a bare-key shortcut like
    /// ⇧P from firing while the user types in the search field, and ⌫ from
    /// trashing the photo behind an alert.
    var photoCommandsAvailable: Bool {
        folder != nil
            && !isLoading
            && !isSearchFieldFocused
            && !showShortcutOverlay
            && !showPairingSheet
            && userError == nil
    }

    /// Run a Go-menu move. The menu takes j, k and ⇧G before the browser's
    /// key handler sees them, so a `g` typed just before must be cancelled
    /// here, or the next `g` would complete a stale `gg`.
    func performGo(_ move: () -> Void) {
        vimKeymap.pendingPrefix = ""
        move()
    }

    /// A photo is selected and culling commands can act on it.
    var canCullCurrent: Bool {
        photoCommandsAvailable && currentURL != nil
    }

    /// The enhancement panel and Export apply to supported stills in a
    /// writable folder.
    var canEnhanceCurrent: Bool {
        guard !isBrowsingArchive, let url = currentURL else { return false }
        return MediaTyping.detect(url) == .staticImage
    }

    var canIncludeSubfolders: Bool {
        folder != nil && !isLoading && !isBrowsingArchive
    }

    /// Switch between the folder's direct contents and its whole subtree.
    func toggleIncludeSubfolders() {
        guard canIncludeSubfolders, let folder else { return }
        let recursive = !loadedRecursively
        Task { await loadFolder(folder, setAsAnchor: false, recursive: recursive) }
    }

    func requestSearch() {
        guard folder != nil, !isLoading, !isBrowsingArchive else { return }
        searchRequestTick &+= 1
    }

    /// Run one culling keystroke (`P`, `X` or a digit) through the vim
    /// keymap and persist it. The keyboard handler and the Photo menu both
    /// land here, so a menu click and a key press are the same edit.
    func performCullingKey(_ character: Character, modifiers: VimModifiers = []) {
        guard ensureActiveFolderContinuity() else { return }
        if isBrowsingArchive {
            lastError = "Archive previews are read-only. Extract the archive in Finder before saving culling changes."
            return
        }
        if isCullingPersistenceBlocked {
            reportBlockedCullingEdit()
            return
        }
        // A culling key is never the second half of a chord; a stray `g`
        // typed before a menu click must not swallow it.
        vimKeymap.pendingPrefix = ""
        let action = vimKeymap.handle(
            keyCharacter: character,
            modifiers: modifiers,
            currentURL: currentURL,
            currentIndex: selectedIndex,
            totalCount: imageURLs.count
        )
        dispatch(action)
    }

    func togglePick() { performCullingKey("P", modifiers: .shift) }
    func toggleReject() { performCullingKey("X", modifiers: .shift) }
    func setColorLabel(_ label: Int) {
        guard (0...9).contains(label), let key = String(label).first else { return }
        performCullingKey(key)
    }

    func revealCurrentInFinder() {
        if let url = currentURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
