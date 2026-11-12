import Foundation

/// Groups photos into bursts and picks the best frame of each. Pure: it
/// takes signatures and returns groups, so every decision is unit-testable
/// without Vision or the file system.
public enum BurstGrouper {
    public struct Item: Sendable {
        public let url: URL
        public let signature: PhotoSignature
        public init(url: URL, signature: PhotoSignature) {
            self.url = url
            self.signature = signature
        }
    }

    /// Walk the photos in capture order. A photo joins the current group when
    /// it was taken within `maxGap` of the previous frame, looks like it, and
    /// still looks like the group's first frame. Otherwise it starts a new
    /// candidate group. Candidates of one photo are not groups.
    public static func groups(
        for items: [Item],
        settings: BurstSettings = .standard
    ) -> [BurstGroup] {
        let ordered = items.sorted {
            if $0.signature.captureTime != $1.signature.captureTime {
                return $0.signature.captureTime < $1.signature.captureTime
            }
            return $0.url.path < $1.url.path
        }
        var runs: [[Item]] = []
        var current: [Item] = []
        for item in ordered {
            if let last = current.last, let first = current.first,
               item.signature.captureTime - last.signature.captureTime <= settings.maxGap,
               let near = last.signature.distance(to: item.signature),
               near <= settings.maxNeighbourDistance,
               let fromStart = first.signature.distance(to: item.signature),
               fromStart <= settings.maxAnchorDistance {
                current.append(item)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [item]
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs.map(makeGroup)
    }

    static func makeGroup(_ run: [Item]) -> BurstGroup {
        let (best, reason) = pickBest(run)
        return BurstGroup(members: run.map(\.url), best: best.url, reason: reason)
    }

    /// Face quality differences smaller than this are noise; sharpness
    /// decides instead.
    static let faceQualityTolerance: Float = 0.03

    /// Ordering of reasons, strongest first:
    /// 1. When any frame has faces, a frame whose faces all have open eyes
    ///    beats one that does not, and a frame with faces beats one without.
    /// 2. Then higher face-capture quality (beyond a small tolerance).
    /// 3. Then sharper.
    /// 4. Then the earlier frame.
    /// The reason shown is "Best faces" when faces took part (some frame has
    /// them), otherwise "Sharpest".
    public static func pickBest(_ run: [Item]) -> (Item, BurstReason) {
        let anyFaces = run.contains { $0.signature.faces != nil }
        var best = run[0]
        for item in run.dropFirst() where isBetter(item, than: best, anyFaces: anyFaces) {
            best = item
        }
        return (best, anyFaces ? .bestFaces : .sharpest)
    }

    private static func isBetter(_ a: Item, than b: Item, anyFaces: Bool) -> Bool {
        if anyFaces {
            switch (a.signature.faces, b.signature.faces) {
            case (nil, .some): return false
            case (.some, nil): return true
            case let (fa?, fb?):
                if fa.eyesOpen != fb.eyesOpen { return fa.eyesOpen }
                if abs(fa.quality - fb.quality) > faceQualityTolerance {
                    return fa.quality > fb.quality
                }
            case (nil, nil): break
            }
        }
        // Strictly sharper only: equal scores keep the earlier frame, because
        // the run is in capture order and `a` is always the later one.
        return a.signature.sharpness > b.signature.sharpness
    }
}
