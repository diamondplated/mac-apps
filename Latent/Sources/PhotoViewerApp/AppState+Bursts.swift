import Foundation
import PhotoBursts
import PhotoViewerCore

// Bursts: starting the background analysis and the two Keep actions. Keep only
// sets pick and reject flags, through the same keymap actions ⇧P and ⇧X use;
// nothing here moves a file.

@MainActor
extension AppState {
    /// Hand the current photo list to the burst analyser. Called whenever the
    /// list changes and when files change in place. Cheap when nothing new
    /// needs analysing.
    func scheduleBurstAnalysis(force: Bool = false) {
        bursts.update(urls: imageURLs, folder: folder, isArchive: isBrowsingArchive, force: force)
    }

    /// The selected photo sits in a burst, the Bursts view is showing, and
    /// the folder can be edited: Keep actions are live.
    var canKeepBurst: Bool {
        canCullCurrent
            && !isBrowsingArchive
            && photoFilter == .bursts
            // A search narrows the stacks; Keep would still reject frames it hides.
            && searchResultURLs == nil
            && bursts.group(containing: currentURL) != nil
    }

    /// Return: pick the suggested frame and reject the rest of its burst.
    func keepBestOfBurst() {
        guard canKeepBurst, let group = bursts.group(containing: currentURL) else { return }
        keep(group.best, in: group)
    }

    /// ⇧Return: the same, for the frame being looked at.
    func keepThisOneOfBurst() {
        guard canKeepBurst, let url = currentURL,
              let group = bursts.group(containing: url) else { return }
        keep(url, in: group)
    }

    private func keep(_ url: URL, in group: BurstGroup) {
        guard ensureActiveFolderContinuity(), ensureWritableSource() else { return }
        guard !isCullingPersistenceBlocked else {
            reportBlockedCullingEdit()
            return
        }
        let returnTo = currentURL
        lastKeepUndo = vimKeymap.keep(url, rejectingRestOf: group.members)
        lastKeepReturn = returnTo
        persistCulling(of: group.members)
        // Move on to the next burst's suggestion, so a whole shoot is one
        // Return per burst. On the last burst, stay on the kept frame.
        if let next = bursts.nextGroupBest(after: url) {
            multiSelection.removeAll()
            select(url: next)
        } else {
            select(url: url)
        }
    }

    /// ⌘Z after a Keep: put the flags back and return to where it was done.
    func undoKeep(_ snapshot: CullingSnapshot) {
        guard ensureActiveFolderContinuity(), !isCullingPersistenceBlocked else { return }
        vimKeymap.restore(snapshot)
        persistCulling(of: snapshot.urls)
        if let url = lastKeepReturn { select(url: url) }
        lastKeepReturn = nil
    }

    private func persistCulling(of urls: [URL]) {
        if let folder { vimKeymap.saveInBackground(folder: folder) }
        // The phone shows picks and rejects too; tell it what changed.
        for url in urls {
            let picked = vimKeymap.isPicked(url)
            let rejected = vimKeymap.isRejected(url)
            let label = vimKeymap.colorLabel(for: url)
            Task { await phoneAccess.publish(url: url, picked: picked, rejected: rejected, label: label) }
        }
    }
}
