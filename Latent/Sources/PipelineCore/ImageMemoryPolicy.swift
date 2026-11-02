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

    public struct LimitError: Error, LocalizedError {
        public var errorDescription: String? {
            "This image exceeds the enhancement memory limit. Use a smaller image or lower scale."
        }
    }
}
