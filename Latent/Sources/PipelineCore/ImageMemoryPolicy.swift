import Foundation

/// Bounds full-image allocations before ImageIO/Core Image can decode or render.
public enum ImageMemoryPolicy {
    public static var defaultLimit: UInt64 {
        min(ProcessInfo.processInfo.physicalMemory / 8, 2 * 1024 * 1024 * 1024)
    }

    /// Conservatively includes source, render and working buffers; also matches
    /// the tiled executor's 28-byte output-pixel budget.
    public static func validate(width: Int, height: Int, scale: Int = 1,
                                maxBytes: UInt64 = defaultLimit) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0, scale > 0 else { throw LimitError() }
        let (w, wo) = width.multipliedReportingOverflow(by: scale)
        let (h, ho) = height.multipliedReportingOverflow(by: scale)
        guard !wo, !ho else { throw LimitError() }
        let (pixels, po) = UInt64(w).multipliedReportingOverflow(by: UInt64(h))
        let (bytes, bo) = pixels.multipliedReportingOverflow(by: 28)
        guard !po, !bo, bytes <= maxBytes else { throw LimitError() }
        return (w, h)
    }

    /// Bound display previews before ImageIO expands HDR or allocates pixels.
    /// Keep full resolution when safe, otherwise halve the longest dimension
    /// until the whole oriented thumbnail fits the same working-memory budget.
    public static func previewMaxDimension(width: Int, height: Int,
                                           maxBytes: UInt64 = defaultLimit) -> Int? {
        guard width > 0, height > 0, maxBytes >= 28 else { return nil }
        let longest = max(width, height)
        if (try? validate(width: width, height: height, maxBytes: maxBytes)) != nil { return longest }
        var target = longest / 2
        while target > 0 {
            let w = max(1, Int(ceil(Double(width) / Double(longest) * Double(target))))
            let h = max(1, Int(ceil(Double(height) / Double(longest) * Double(target))))
            if (try? validate(width: w, height: h, maxBytes: maxBytes)) != nil { return target }
            target /= 2
        }
        return 1
    }

    public struct LimitError: Error, LocalizedError {
        public var errorDescription: String? {
            "This image exceeds the enhancement memory limit. Use a smaller image or lower scale."
        }
    }
}
