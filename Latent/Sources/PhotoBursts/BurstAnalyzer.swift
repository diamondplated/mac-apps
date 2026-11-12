import Foundation

/// Computes signatures for a folder's photos in the background: reuses what
/// is already known in memory or in the on-disk cache, computes the rest with
/// a small, fixed amount of parallelism, reports progress, and stops quickly
/// when its task is cancelled.
public enum BurstAnalyzer {
    public typealias Extractor = @Sendable (URL) -> PhotoSignature?

    /// Two workers: enough to keep a Vision pass busy, few enough that the
    /// app's own decoding and drawing keep most of the cores.
    public static let defaultConcurrency = 2

    /// Returns a signature for every photo that could be read. `progress`
    /// receives (finished, total), cache hits included, and is called at most
    /// every few photos plus once at the end.
    public static func analyze(
        urls: [URL],
        known: [URL: StampedSignature] = [:],
        cache: BurstCache?,
        concurrency: Int = defaultConcurrency,
        extractor: @escaping Extractor = { BurstSignatureExtractor.signature(for: $0) },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [URL: StampedSignature] {
        let disk = cache?.load() ?? [:]
        var result: [URL: StampedSignature] = [:]
        var pending: [(URL, FileStamp)] = []
        for url in urls {
            if Task.isCancelled { break }
            guard let stamp = FileStamp.read(url) else { continue }
            if let hit = known[url], hit.stamp == stamp {
                result[url] = hit
            } else if let key = cache?.relativePath(of: url), let hit = disk[key], hit.stamp == stamp {
                result[url] = hit
            } else {
                pending.append((url, stamp))
            }
        }
        let total = urls.count
        var finished = result.count
        progress(finished, total)

        await withTaskGroup(of: (URL, StampedSignature?).self) { group in
            var next = 0
            func launch() {
                guard next < pending.count, !Task.isCancelled else { return }
                let (url, stamp) = pending[next]
                next += 1
                group.addTask {
                    if Task.isCancelled { return (url, nil) }
                    guard let signature = extractor(url) else { return (url, nil) }
                    return (url, StampedSignature(stamp: stamp, signature: signature))
                }
            }
            for _ in 0..<max(1, concurrency) { launch() }
            while let (url, entry) = await group.next() {
                finished += 1
                if let entry { result[url] = entry }
                if finished % 8 == 0 { progress(finished, total) }
                launch()
            }
        }
        progress(finished, total)

        if let cache, result.count != 0 || !disk.isEmpty {
            // Start from what is on disk right now (another run may have saved
            // since this one began), so a pass over part of a tree, or a
            // cancelled one, never drops entries it did not look at. Entries
            // whose files are gone are pruned.
            let latest = cache.load()
            var entries = latest.filter { key, _ in
                FileManager.default.fileExists(atPath: cache.folderPath + "/" + key)
            }
            for (url, entry) in result { entries[cache.relativePath(of: url)] = entry }
            // Only rewrite when something changed, so a warm visit does no I/O.
            if entries != latest { cache.save(entries) }
        }
        return result
    }
}
