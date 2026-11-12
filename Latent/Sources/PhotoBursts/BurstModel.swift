import Foundation

/// What Latent remembers about one photo for burst detection: when it was
/// taken, a Vision feature print for likeness, how sharp it is, and what
/// Vision saw of any faces. Everything here is derived from the pixels and
/// the file's timestamps, so it can be cached and compared without reopening
/// the photo.
public struct PhotoSignature: Codable, Sendable, Equatable {
    /// Seconds since 1970 of capture: EXIF original time with sub-seconds,
    /// or the file's modification time when the photo carries none.
    public var captureTime: Double
    /// The feature print's floats, little-endian `Float32`.
    public var featurePrint: Data
    /// Variance of the Laplacian over the centre-weighted region of a
    /// downscaled luminance image. Higher is sharper; only meaningful when
    /// compared between frames of one group.
    public var sharpness: Double
    /// Nil when Vision found no face.
    public var faces: FaceSummary?

    public init(captureTime: Double, featurePrint: Data, sharpness: Double, faces: FaceSummary? = nil) {
        self.captureTime = captureTime
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.faces = faces
    }

    public init(captureTime: Double, featurePrint: [Float], sharpness: Double, faces: FaceSummary? = nil) {
        self.init(
            captureTime: captureTime,
            featurePrint: featurePrint.withUnsafeBufferPointer { Data(buffer: $0) },
            sharpness: sharpness,
            faces: faces
        )
    }

    /// Euclidean distance between two feature prints, or nil when they
    /// cannot be compared (different lengths, empty).
    public func distance(to other: PhotoSignature) -> Float? {
        let count = featurePrint.count / MemoryLayout<Float>.size
        guard count > 0, featurePrint.count == other.featurePrint.count else { return nil }
        return featurePrint.withUnsafeBytes { a in
            other.featurePrint.withUnsafeBytes { b in
                var sum: Float = 0
                for i in 0..<count {
                    let d = a.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                        - b.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                    sum += d * d
                }
                return sum.squareRoot()
            }
        }
    }
}

/// Faces in a frame, boiled down to what picking a frame needs.
public struct FaceSummary: Codable, Sendable, Equatable {
    public var count: Int
    /// Mean of Vision's face-capture quality (0 to 1) over the faces.
    public var quality: Float
    /// True when every face found has its eyes open.
    public var eyesOpen: Bool

    public init(count: Int, quality: Float, eyesOpen: Bool) {
        self.count = count
        self.quality = quality
        self.eyesOpen = eyesOpen
    }
}

/// Why a frame was suggested. Shown to the user, never hidden.
public enum BurstReason: String, Codable, Sendable, Equatable {
    case sharpest
    case bestFaces

    public var label: String {
        switch self {
        case .sharpest: "Sharpest"
        case .bestFaces: "Best faces"
        }
    }
}

/// A run of near-identical photos and the frame Latent suggests keeping.
public struct BurstGroup: Sendable, Equatable, Identifiable {
    /// The earliest frame's path; stable while the group's first frame is.
    public var id: String { members[0].path }
    /// Frames in capture order. Always at least two.
    public let members: [URL]
    public let best: URL
    public let reason: BurstReason

    public init(members: [URL], best: URL, reason: BurstReason) {
        precondition(members.count >= 2 && members.contains(best))
        self.members = members
        self.best = best
        self.reason = reason
    }

    public var others: [URL] { members.filter { $0 != best } }
}

/// How alike and how close in time two photos must be to share a group.
public struct BurstSettings: Sendable, Equatable {
    /// Largest gap between neighbouring frames, in seconds. Real bursts fire
    /// several frames a second; a photographer re-framing the same subject
    /// takes a second or two. Past four seconds it is a new moment.
    public var maxGap: Double
    /// Largest feature-print distance between neighbouring frames.
    public var maxNeighbourDistance: Float
    /// Largest distance from a group's first frame. Neighbour-to-neighbour
    /// chaining alone lets a slow pan drift into a different scene, so a
    /// frame must also still resemble where the group started.
    public var maxAnchorDistance: Float

    public init(maxGap: Double, maxNeighbourDistance: Float, maxAnchorDistance: Float) {
        self.maxGap = maxGap
        self.maxNeighbourDistance = maxNeighbourDistance
        self.maxAnchorDistance = maxAnchorDistance
    }

    /// Calibrated against Vision's feature prints on generated fixtures
    /// (distances are Euclidean over the print's floats):
    /// - the same scene nudged up to 8 px with brightness drift: 0.08 to 0.15
    /// - the same scene partly out of focus: 0.05 to 0.13
    /// - out of focus and nudged at once, the worst case tried: 0.32
    /// - unrelated scenes: 0.46 to 0.73, nearest 0.46
    /// A neighbour limit of 0.38 clears all of those and stays well below the
    /// unrelated scenes; the anchor limit of 0.45 lets a group drift a little
    /// over a run but stays just under the nearest unrelated scene. The cut is
    /// deliberately conservative: a missed group costs a few extra
    /// comparisons, a wrong merge would suggest rejecting a different shot.
    public static let standard = BurstSettings(
        maxGap: 4,
        maxNeighbourDistance: 0.38,
        maxAnchorDistance: 0.45
    )
}
