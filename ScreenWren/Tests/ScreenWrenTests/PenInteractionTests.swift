import AppKit
import PaperKit
import PencilKit
import XCTest

@testable import ScreenWren

final class PenInteractionTests: XCTestCase {
    @MainActor private func mouse(_ type: NSEvent.EventType, at point: CGPoint,
                                 in view: NSView, number: Int) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: number,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func coloredPixels(_ image: CGImage, highlight: Bool, in rectangle: CGRect? = nil) throws -> Int {
        let pixels = NSBitmapImageRep(cgImage: image)
        let area = (rectangle ?? CGRect(x: 0, y: 0, width: image.width, height: image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var count = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let color = try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if highlight {
                    if color.redComponent > 0.7 && color.greenComponent > 0.5 && color.blueComponent < 0.85 { count += 1 }
                } else if color.redComponent > 0.65 && color.greenComponent < 0.45 && color.blueComponent < 0.45 {
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor func testPenAndHighlightCurvedMouseDragsChangeMarkupAndRenderedPixels() async throws {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 400, height: 300) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let controller = EditorWindowController(image: image, copied: false) { _ in }
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(window.contentViewController as? EditorViewController)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        editor.view.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(editor.children.compactMap { $0 as? PaperMarkupViewController }.first)
        let imageView = try XCTUnwrap(canvas.contentView)
        let header = try XCTUnwrap(editor.view.subviews.first { $0 is NSVisualEffectView })
        let tools = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorQuickTools" } as? NSStackView)
        let buttons = tools.views.compactMap { $0 as? NSButton }
        let finishActions = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorFinishActions" } as? NSStackView)
        let finishButtons = finishActions.views.compactMap { $0 as? NSButton }
        let copyButton = try XCTUnwrap(finishButtons.first { $0.title == "Copy Edited Image" })
        for title in ["Pen", "Highlight"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            XCTAssertTrue(button.isEnabled, "Drawing tools must remain switchable between strokes")
            button.performClick(nil)
            let overlay = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? AnnotationDrawingView }.first)
            XCTAssertFalse(canvas.isEditable, "The gesture overlay owns mouse input while the native canvas remains underneath")
            XCTAssertTrue(finishButtons.allSatisfy(\.isEnabled), "Persistent freehand mode must keep finish actions available")
            let initialImage = try await editor.renderEditedImage()
            var previousPixels = try coloredPixels(initialImage, highlight: title == "Highlight")
            for stroke in 0..<2 {
                let before = try await canvas.markup?.dataRepresentation()
                let points = (0...16).map { index in
                    let t = CGFloat(index) / 16
                    return CGPoint(x: 70 + 250 * t, y: CGFloat(85 + stroke * 120) + 35 * sin(t * .pi * 2))
                }
                let start = points[0]
                let hit = try XCTUnwrap(editor.view.hitTest(imageView.convert(start, to: editor.view)))
                XCTAssertTrue(hit === overlay, "The visible drawing overlay must receive the routed canvas click")
                window.sendEvent(try mouse(.leftMouseDown, at: start, in: imageView, number: 1))
                for (index, point) in points.dropFirst().enumerated() {
                    window.sendEvent(try mouse(.leftMouseDragged, at: point, in: imageView, number: index + 2))
                    try await Task.sleep(for: .milliseconds(10))
                }
                window.sendEvent(try mouse(.leftMouseUp, at: try XCTUnwrap(points.last), in: imageView, number: 19))
                try await Task.sleep(for: .milliseconds(50))
                let after = try await canvas.markup?.dataRepresentation()
                XCTAssertNotEqual(before, after, "\(title) stroke \(stroke + 1) must add editable drawing content")
                let rendered = try await editor.renderEditedImage()
                let currentPixels = try coloredPixels(rendered, highlight: title == "Highlight")
                XCTAssertGreaterThan(currentPixels, previousPixels + 150,
                                     "\(title) stroke \(stroke + 1) must appear in exported pixels")
                // The first crest is away from both the endpoint chord and its vertical mirror.
                let crest = points[4]
                let expected = CGRect(x: crest.x - 9, y: CGFloat(rendered.height) - crest.y - 9, width: 18, height: 18)
                let mirrored = CGRect(x: crest.x - 9, y: crest.y - 9, width: 18, height: 18)
                let chord = CGRect(x: crest.x - 9, y: CGFloat(rendered.height) - start.y - 9, width: 18, height: 18)
                XCTAssertGreaterThan(try coloredPixels(rendered, highlight: title == "Highlight", in: expected), 12,
                                     "\(title) must follow the curved drag at its asymmetric crest")
                XCTAssertEqual(try coloredPixels(rendered, highlight: title == "Highlight", in: mirrored), 0,
                               "\(title) must not mirror the user's stroke vertically")
                XCTAssertEqual(try coloredPixels(rendered, highlight: title == "Highlight", in: chord), 0,
                               "\(title) must preserve the curve rather than connect only its endpoints")
                XCTAssertTrue(overlay.superview === editor.view, "A second stroke must not require selecting the tool again")
                XCTAssertTrue(copyButton.isEnabled)
                XCTAssertTrue(finishButtons.allSatisfy(\.isEnabled))
                window.undoManager?.undo()
                let undone = try await editor.renderEditedImage()
                XCTAssertEqual(try coloredPixels(undone, highlight: title == "Highlight"), previousPixels,
                               "Undo must remove exactly the latest stroke")
                window.undoManager?.redo()
                let redone = try await editor.renderEditedImage()
                XCTAssertEqual(try coloredPixels(redone, highlight: title == "Highlight"), currentPixels)
                previousPixels = currentPixels
            }
        }
        // Start Copy from persistent Pen mode, then cancel synchronously before its
        // MainActor task can run. This exercises the action without writing the clipboard.
        try XCTUnwrap(buttons.first { $0.title == "Pen" }).performClick(nil)
        let clipboardCount = NSPasteboard.general.changeCount
        copyButton.performClick(nil)
        let startedCopy = !copyButton.isEnabled
        let dismissedDrawing = !editor.view.subviews.contains { $0 is AnnotationDrawingView }
        editor.cancelPendingAction()
        XCTAssertTrue(startedCopy, "Copy must begin after completed Pen strokes while drawing mode remains selected")
        XCTAssertTrue(dismissedDrawing, "Copy must finish persistent drawing mode")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount, "The cancelled test copy must leave the clipboard untouched")
    }
}
