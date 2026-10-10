import AppKit
import Carbon.HIToolbox
import PencilKit

enum AnnotationDrawingTool {
    case arrow
    case box
    case pen
    case highlighter

    var isFreehand: Bool { self == .pen || self == .highlighter }
    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .pen: "Pen"
        case .highlighter: "Highlight"
        }
    }
    var prompt: String {
        switch self {
        case .arrow: "Drag from arrow tail to tip — Shift snaps the angle, Esc cancels"
        case .box: "Drag a box around the detail — Esc cancels"
        case .pen: "Drag to draw — Select or Esc finishes drawing"
        case .highlighter: "Drag to highlight — Select or Esc finishes drawing"
        }
    }
}

struct AnnotationGesture {
    let start: CGPoint
    let end: CGPoint
    let points: [CGPoint]

    init(start: CGPoint, end: CGPoint, points: [CGPoint] = []) {
        self.start = start
        self.end = end
        self.points = points
    }
}

// This temporary view collects a gesture. The finished object is native,
// editable PaperKit markup rather than pixels painted onto the screenshot.
final class AnnotationDrawingView: NSView {
    let tool: AnnotationDrawingTool
    let inkingTool: PKInkingTool?
    var interactionBounds = CGRect.null
    var interactionBoundsProvider: (() -> CGRect)?
    var onFinish: ((AnnotationGesture?) -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?
    private var points: [CGPoint] = []

    init(frame: CGRect, tool: AnnotationDrawingTool, inkingTool: PKInkingTool? = nil) {
        self.tool = tool
        self.inkingTool = inkingTool
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Draw \(tool.title.lowercased())")
        setAccessibilityHelp(tool.prompt)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var drawingBounds: CGRect {
        let content = interactionBoundsProvider?() ?? interactionBounds
        return content.isNull ? bounds : content.intersection(bounds)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = nil
        end = nil
        points = []
        let point = convert(event.locationInWindow, from: nil)
        guard drawingBounds.contains(point) else { NSSound.beep(); return }
        start = point
        end = point
        points = [point]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        var point = convert(event.locationInWindow, from: nil)
        if tool == .arrow, event.modifierFlags.contains(.shift) {
            let dx = point.x - start.x, dy = point.y - start.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let distance = hypot(dx, dy)
            point = CGPoint(x: start.x + cos(angle) * distance, y: start.y + sin(angle) * distance)
        }
        end = clamped(point)
        if tool.isFreehand, let end,
           points.last.map({ hypot(end.x - $0.x, end.y - $0.y) >= 0.5 }) ?? true {
            points.append(end)
        }
        setAccessibilityValue("\(tool.title) from \(Int(start.x)), \(Int(start.y)) to \(Int(end!.x)), \(Int(end!.y))")
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        mouseDragged(with: event)
        guard let end else { return }
        let rectangle = normalizedRect(from: start, to: end)
        let valid = tool.isFreehand ? points.count >= 2
            : tool == .arrow ? hypot(end.x - start.x, end.y - start.y) >= 4
            : rectangle.width >= 4 && rectangle.height >= 4
        guard valid else {
            self.start = nil; self.end = nil
            needsDisplay = true
            NSSound.beep()
            return
        }
        self.start = nil
        self.end = nil
        let gesture = AnnotationGesture(start: start, end: end, points: points)
        points = []
        needsDisplay = true
        onFinish?(gesture)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onFinish?(nil) }
        else { super.keyDown(with: event) }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, drawingBounds.minX), drawingBounds.maxX),
                y: min(max(point.y, drawingBounds.minY), drawingBounds.maxY))
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let start, let end else { return }
        (inkingTool?.color ?? .systemRed).setStroke()
        let path = NSBezierPath()
        path.lineWidth = inkingTool?.width ?? 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if tool.isFreehand {
            path.move(to: start)
            for point in points.dropFirst() { path.line(to: point) }
        } else if tool == .box {
            path.appendRect(normalizedRect(from: start, to: end))
        } else {
            path.move(to: start)
            path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            for offset: CGFloat in [-.pi / 6, .pi / 6] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - 12 * cos(angle + offset), y: end.y - 12 * sin(angle + offset)))
            }
        }
        path.stroke()
    }
}
