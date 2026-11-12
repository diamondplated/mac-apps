import Foundation
import Observation
import PhotoBursts

/// The folder's bursts: which photos belong together and which frame Latent
/// suggests. Analysis runs in the background after a folder loads, never
/// blocks browsing, and is cancelled when the folder changes or closes.
@MainActor
@Observable
final class BurstState {
    enum Phase: Equatable {
        case idle
        case analyzing(done: Int, total: Int)
        case ready
        /// Too many photos to analyse in the background.
        case skipped
    }

    /// Above this many photos the background pass is not started: a 100,000
    /// photo recursive folder would run for hours and hold every signature
    /// in memory.
    nonisolated static let photoLimit = 10_000

    private(set) var phase: Phase = .idle
    /// In folder order (by each group's first photo).
    private(set) var groups: [BurstGroup] = []

    @ObservationIgnored private var groupIndex: [URL: Int] = [:]
    @ObservationIgnored private var signatures: [URL: StampedSignature] = [:]
    @ObservationIgnored private var analysedSet: Set<URL> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // MARK: - Reading

    func group(containing url: URL?) -> BurstGroup? {
        guard let url, let i = groupIndex[url] else { return nil }
        return groups[i]
    }

    /// What the Bursts view shows: each group's suggested frame as one stack,
    /// except the group holding `current`, which is open and lists all of its
    /// frames in capture order.
    func visibleURLs(current: URL?) -> [URL] {
        let open = current.flatMap { groupIndex[$0] }
        var result: [URL] = []
        result.reserveCapacity(groups.count)
        for (i, group) in groups.enumerated() {
            if i == open { result.append(contentsOf: group.members) } else { result.append(group.best) }
        }
        return result
    }

    /// The suggested frame of the group after the one holding `url`.
    func nextGroupBest(after url: URL) -> URL? {
        guard let i = groupIndex[url], i + 1 < groups.count else { return nil }
        return groups[i + 1].best
    }

    // MARK: - Updating

    /// Called whenever the photo list changes. Regroups from what is already
    /// known right away (so a trashed photo leaves its group at once) and
    /// schedules a background pass for anything new.
    func update(urls: [URL], folder: URL?, isArchive: Bool, force: Bool = false) {
        guard let folder, urls.count >= 2 else {
            reset()
            return
        }
        // Videos and GIFs are never grouped; animated PNG/HEIC are rejected
        // by the extractor itself.
        let candidates = urls.filter { Self.mayBeStill($0) }
        guard candidates.count >= 2 else {
            reset()
            return
        }
        guard candidates.count <= Self.photoLimit else {
            cancelWork()
            signatures = [:]
            analysedSet = []
            setGroups([])
            phase = .skipped
            return
        }
        regroup(candidates, order: urls)
        let set = Set(candidates)
        if !force, phase == .ready, set == analysedSet { return }
        if phase != .ready { phase = .analyzing(done: 0, total: candidates.count) }

        cancelWork()
        generation += 1
        let gen = generation
        let known = signatures
        // The state lives as long as the app, so the task may hold it.
        let owner = self
        task = Task {
            // Let a burst of watcher updates settle before doing real work.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let cache = isArchive ? nil : try? BurstCache(folder: folder)
            let inner = Task.detached(priority: .utility) {
                await BurstAnalyzer.analyze(
                    urls: candidates, known: known, cache: cache,
                    progress: { done, total in
                        Task { @MainActor in
                            owner.noteProgress(done: done, total: total, generation: gen)
                        }
                    }
                )
            }
            let result = await withTaskCancellationHandler {
                await inner.value
            } onCancel: {
                inner.cancel()
            }
            guard !Task.isCancelled else { return }
            owner.finish(result: result, candidates: candidates, order: urls, generation: gen)
        }
    }

    /// Leave the folder: stop the background pass and forget everything.
    func reset() {
        cancelWork()
        signatures = [:]
        analysedSet = []
        setGroups([])
        phase = .idle
    }

    // MARK: - Internals

    private func cancelWork() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func noteProgress(done: Int, total: Int, generation gen: Int) {
        guard gen == generation else { return }
        // Only advance a bar that is already showing; a late callback must
        // never turn a finished analysis back into a running one.
        if case .analyzing(let previous, _) = phase, done < total, done >= previous {
            phase = .analyzing(done: done, total: total)
        }
    }

    private func finish(
        result: [URL: StampedSignature], candidates: [URL], order: [URL], generation gen: Int
    ) {
        guard gen == generation else { return }
        generation += 1
        signatures = result
        analysedSet = Set(candidates)
        regroup(candidates, order: order)
        phase = .ready
        task = nil
    }

    private func regroup(_ candidates: [URL], order: [URL]) {
        var items: [BurstGrouper.Item] = []
        for url in candidates {
            if let entry = signatures[url] { items.append(.init(url: url, signature: entry.signature)) }
        }
        var position: [URL: Int] = [:]
        position.reserveCapacity(order.count)
        for (i, url) in order.enumerated() { position[url] = i }
        // Folder order: each group sits where its earliest-listed photo does.
        setGroups(BurstGrouper.groups(for: items).sorted { a, b in
            let pa = a.members.compactMap { position[$0] }.min() ?? .max
            let pb = b.members.compactMap { position[$0] }.min() ?? .max
            return pa < pb
        })
    }

    private func setGroups(_ new: [BurstGroup]) {
        guard new != groups else { return }
        groups = new
        var index: [URL: Int] = [:]
        for (i, group) in new.enumerated() {
            for url in group.members { index[url] = i }
        }
        groupIndex = index
    }

    nonisolated static func mayBeStill(_ url: URL) -> Bool {
        MediaTyping.staticImageExts.contains(url.pathExtension.lowercased())
    }
}
