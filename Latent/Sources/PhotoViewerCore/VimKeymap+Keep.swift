import Foundation

/// The pick and reject flags of some photos before a keep action, so one
/// undo puts them back exactly.
public struct CullingSnapshot: Sendable, Equatable {
    public let urls: [URL]
    let picked: Set<URL>
    let rejected: Set<URL>
}

extension VimKeymap {
    /// Pick `keep` and reject every other photo in `group`. Each flag change
    /// goes through `handle` with the same ⇧P and ⇧X keystrokes the keyboard
    /// sends, so the pick/reject exclusivity and change tracking are the ones
    /// every other cull uses. Already-correct photos are left alone, because
    /// those keys toggle. Labels are untouched, and nothing is trashed.
    /// Returns the previous flags for undo.
    @discardableResult
    public func keep(_ keep: URL, rejectingRestOf group: [URL]) -> CullingSnapshot {
        let urls = group.contains(keep) ? group : group + [keep]
        let snapshot = CullingSnapshot(
            urls: urls,
            picked: Set(urls.filter(isPicked)),
            rejected: Set(urls.filter(isRejected))
        )
        for url in urls {
            if url == keep {
                if !isPicked(url) { press("P", on: url) }
            } else if !isRejected(url) {
                press("X", on: url)
            }
        }
        return snapshot
    }

    /// Put the flags `keep` changed back as they were.
    public func restore(_ snapshot: CullingSnapshot) {
        for url in snapshot.urls {
            if snapshot.picked.contains(url) {
                if !isPicked(url) { press("P", on: url) }
            } else if snapshot.rejected.contains(url) {
                if !isRejected(url) { press("X", on: url) }
            } else {
                // Neither: toggle off whichever is set.
                if isPicked(url) { press("P", on: url) }
                if isRejected(url) { press("X", on: url) }
            }
        }
    }

    private func press(_ key: Character, on url: URL) {
        pendingPrefix = ""
        _ = handle(keyCharacter: key, modifiers: .shift, currentURL: url, currentIndex: nil, totalCount: 0)
    }
}
