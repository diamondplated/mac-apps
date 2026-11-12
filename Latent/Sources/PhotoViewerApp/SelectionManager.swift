import Foundation

/// Focused selection state extracted from AppState: the primary selection
/// and the multi-selection. Filter-aware navigation lives on AppState
/// (`selectNextVisible` and friends) because it needs the active filter.
///
/// Operates on a reference to the parent's `imageURLs` array via a closure
/// so the selection stays in sync without duplicating the URL list.
@MainActor
@Observable
final class SelectionManager {
    /// Index of the currently-selected image (if any). The "primary" focus —
    /// what the detail view shows. In multi-select mode this is the most
    /// recent click + the anchor for shift-click range extension.
    var selectedIndex: Int? = nil

    /// Multi-selection set. Empty when in single-select mode (the typical
    /// case). When non-empty, Backspace trashes ALL of these instead of
    /// just the primary, and the toolbar shows a "N selected" pill.
    var multiSelection: Set<URL> = []

    /// Closure that returns the current image URL list. Avoids duplicating
    /// the array while keeping selection logic decoupled from AppState.
    var imageURLs: () -> [URL] = { [] }

    /// Convenience: the currently-selected URL, if valid.
    var currentURL: URL? {
        guard let i = selectedIndex else { return nil }
        let urls = imageURLs()
        guard i < urls.count else { return nil }
        return urls[i]
    }

    // MARK: - Navigation

    /// Jump to a specific URL (no-op if it's not in the current folder).
    /// Used by map-cluster selection, search results and the phone.
    func select(url: URL) {
        if let i = imageURLs().firstIndex(of: url) {
            selectedIndex = i
        }
    }

    // MARK: - Multi-selection

    /// Drop the multi-selection back to single-select mode.
    func clearMultiSelection() {
        multiSelection.removeAll()
    }

    // MARK: - Maintenance

    /// Called after images are removed (trash, rescan) to keep the
    /// selection valid. Tries to preserve the selected URL; falls back
    /// to the position or clamps.
    func adjustAfterRemoval(removedURLs: Set<URL>, previousURL: URL?) {
        let urls = imageURLs()
        multiSelection.subtract(removedURLs)
        if urls.isEmpty {
            selectedIndex = nil
        } else if let previousURL, let newIdx = urls.firstIndex(of: previousURL) {
            selectedIndex = newIdx
        } else {
            selectedIndex = min(selectedIndex ?? 0, urls.count - 1)
        }
    }

    /// Reset everything. Called on folder close/change.
    func reset() {
        selectedIndex = nil
        multiSelection.removeAll()
    }
}
