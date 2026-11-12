import AppKit

// Preferences contain behavior and dimensions only, never captured content.
enum CaptureDestination: String, CaseIterable, Codable {
    case clipboard, editor, pin, save, review
    var title: String {
        switch self {
        case .clipboard: "Copy only"
        case .editor: "Copy and open editor"
        case .pin: "Copy and pin"
        case .save: "Save…"
        case .review: "Review redactions before copying"
        }
    }
    var copiesImmediately: Bool { self == .clipboard || self == .editor || self == .pin }
}

struct SelectionPreset: Codable, Equatable {
    var name: String
    var width: Int
    var height: Int
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (4...16_000).contains(width)
            && (4...16_000).contains(height)
    }
}

struct SelectionOptions: Equatable {
    var adjustBeforeCapture = false
    var fixedSize: CGSize?
    var aspectRatio: CGFloat?
}

@MainActor
final class WorkflowPreferences {
    static let shared = WorkflowPreferences()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var destination: CaptureDestination {
        get { CaptureDestination(rawValue: defaults.string(forKey: "capture.destination") ?? "") ?? .clipboard }
        set { defaults.set(newValue.rawValue, forKey: "capture.destination") }
    }
    var showsThumbnail: Bool {
        get { defaults.bool(forKey: "capture.thumbnail") }
        set { defaults.set(newValue, forKey: "capture.thumbnail") }
    }
    var adjustBeforeCapture: Bool {
        get { defaults.bool(forKey: "selection.adjust") }
        set { defaults.set(newValue, forKey: "selection.adjust") }
    }
    var fixedSize: CGSize? {
        get {
            let w = defaults.integer(forKey: "selection.width")
            let h = defaults.integer(forKey: "selection.height")
            return (4...16_000).contains(w) && (4...16_000).contains(h) ? CGSize(width: w, height: h) : nil
        }
        set {
            defaults.set(newValue.map { Int($0.width) } ?? 0, forKey: "selection.width")
            defaults.set(newValue.map { Int($0.height) } ?? 0, forKey: "selection.height")
        }
    }
    var aspectRatio: CGFloat? {
        get {
            let r = defaults.double(forKey: "selection.ratio")
            return r.isFinite && r > 0 ? r : nil
        }
        set { defaults.set(newValue ?? 0, forKey: "selection.ratio") }
    }
    var presets: [SelectionPreset] {
        get {
            guard let data = defaults.data(forKey: "selection.presets"),
                let values = try? JSONDecoder().decode([SelectionPreset].self, from: data)
            else { return [] }
            return Array(values.filter(\.isValid).prefix(20))
        }
        set {
            defaults.set(
                try? JSONEncoder().encode(Array(newValue.filter(\.isValid).prefix(20))), forKey: "selection.presets")
        }
    }
    var selectionOptions: SelectionOptions {
        SelectionOptions(adjustBeforeCapture: adjustBeforeCapture, fixedSize: fixedSize, aspectRatio: aspectRatio)
    }
}

// Clamp without shrinking when moving; resize remains inside the desktop bounds.
func adjustedSelection(
    _ rectangle: CGRect, dx: CGFloat, dy: CGFloat, resizing: Bool, bounds: CGRect, ratio: CGFloat? = nil,
    minimumSize: CGFloat = 4
) -> CGRect {
    var result = rectangle
    if resizing {
        var width = max(minimumSize, rectangle.width + dx)
        var height = max(minimumSize, rectangle.height + dy)
        if let ratio, ratio > 0 {
            if dx != 0 { height = width / ratio } else { width = height * ratio }
            let fit = min(1, (bounds.maxX - rectangle.minX) / width, (bounds.maxY - rectangle.minY) / height)
            width *= fit
            height *= fit
        }
        result.size = CGSize(
            width: min(width, bounds.maxX - result.minX), height: min(height, bounds.maxY - result.minY))
    } else {
        result.origin.x = min(max(bounds.minX, rectangle.minX + dx), bounds.maxX - rectangle.width)
        result.origin.y = min(max(bounds.minY, rectangle.minY + dy), bounds.maxY - rectangle.height)
    }
    return result
}

func constrainedSelection(
    from start: CGPoint, to end: CGPoint, bounds: CGRect, fixedSize: CGSize?, ratio: CGFloat?, pixelScale: CGFloat = 1
)
    -> CGRect
{
    let target = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX), y: min(max(end.y, bounds.minY), bounds.maxY))
    if let fixedSize {
        let size = CGSize(width: min(fixedSize.width, bounds.width), height: min(fixedSize.height, bounds.height))
        let x = ((target.x - size.width / 2) * pixelScale).rounded() / pixelScale
        let y = ((target.y - size.height / 2) * pixelScale).rounded() / pixelScale
        return CGRect(
            x: min(max(x, bounds.minX), bounds.maxX - size.width),
            y: min(max(y, bounds.minY), bounds.maxY - size.height), width: size.width,
            height: size.height)
    }
    var dx = target.x - start.x
    var dy = target.y - start.y
    if let ratio, ratio > 0 {
        let width = min(abs(dx), abs(dy) * ratio)
        dx = (dx < 0 ? -1 : 1) * width
        dy = (dy < 0 ? -1 : 1) * width / ratio
    }
    return normalizedRect(from: start, to: CGPoint(x: start.x + dx, y: start.y + dy)).intersection(bounds)
}
