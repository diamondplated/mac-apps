import AppKit
import PaperKit
import PencilKit
import XCTest
@testable import ScreenWren

final class NativeToolbarInteractionTests: XCTestCase {
    @MainActor private func fixture() throws -> EditorWindowController {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 400, height: 300) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        return EditorWindowController(image: image, copied: false) { _ in }
    }

    @MainActor private func drag(_ overlay: AnnotationDrawingView, from start: CGPoint, to end: CGPoint) throws {
        let window = try XCTUnwrap(overlay.window)
        let root = try XCTUnwrap(window.contentView)
        XCTAssertTrue(root.hitTest(overlay.convert(start, to: root)) === overlay)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    @MainActor func testNativeShapeAndTextCommandsReachEditableRenderedMarkup() async throws {
        let controller = try fixture()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(window.contentViewController as? EditorViewController)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        editor.view.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(editor.children.compactMap { $0 as? MarkupToolbarViewController }.first)
        let canvas = try XCTUnwrap(editor.children.compactMap { $0 as? PaperMarkupViewController }.first)
        let delegate = try XCTUnwrap(toolbar.delegate)
        XCTAssertTrue(delegate is NativeMarkupToolbarAdapter)
        let imageView = try XCTUnwrap(canvas.contentView)

        for tool: AnnotationDrawingTool in [.arrow, .box] {
            let before = try await canvas.markup?.dataRepresentation()
            if tool == .arrow {
                delegate.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
            } else {
                delegate.markupToolbarViewController(toolbar, insertNewShape: .rectangle)
            }
            let overlay = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? AnnotationDrawingView }.first)
            XCTAssertEqual(overlay.tool, tool)
            try drag(overlay, from: imageView.convert(CGPoint(x: 60, y: 70), to: overlay),
                     to: imageView.convert(CGPoint(x: 220, y: 130), to: overlay))
            XCTAssertFalse(editor.view.subviews.contains { $0 is AnnotationDrawingView })
            let after = try await canvas.markup?.dataRepresentation()
            XCTAssertNotEqual(before, after, "Native toolbar \(tool) must create editable markup")
            let bitmap = NSBitmapImageRep(cgImage: try await editor.renderEditedImage())
            var redPixels = 0
            for y in 160..<240 {
                for x in 50..<230 {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.redComponent > 0.65 && color.greenComponent < 0.45 && color.blueComponent < 0.45 {
                        redPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(redPixels, 150, "Native toolbar \(tool) must appear in exported pixels")
            window.undoManager?.undo()
        }

        let beforeText = try await canvas.markup?.dataRepresentation()
        delegate.markupToolbarViewControllerInsertNewTextbox(toolbar)
        let afterText = try await canvas.markup?.dataRepresentation()
        XCTAssertNotEqual(beforeText, afterText, "Native Text must insert an editable textbox")
        XCTAssertEqual(window.undoManager?.undoActionName, "Text")
    }

    @MainActor func testNativeInkPreservesStyleAndSelectionEndsPersistentDrawing() throws {
        let controller = try fixture()
        defer { controller.close() }
        controller.showWindow(nil)
        let editor = try XCTUnwrap(controller.window?.contentViewController as? EditorViewController)
        editor.view.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(editor.children.compactMap { $0 as? MarkupToolbarViewController }.first)
        let adapter = try XCTUnwrap(toolbar.delegate as? NativeMarkupToolbarAdapter)
        let chosen = PKInkingTool(.marker, color: NSColor(srgbRed: 0.15, green: 0.4, blue: 0.8, alpha: 0.6), width: 11.5)
        adapter.withSuppressedCallbacks {
            toolbar.selectedDrawingTool = chosen
            toolbar.selectedIndirectPointerTouchMode = .drawing
        }
        adapter.markupToolbarViewControllerSelectedDrawingToolChanged(toolbar)
        let overlay = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? AnnotationDrawingView }.first)
        XCTAssertTrue(overlay.tool.isFreehand)
        XCTAssertEqual(overlay.tool, .highlighter)
        let actual = try XCTUnwrap(overlay.inkingTool)
        XCTAssertEqual(actual.inkType, chosen.inkType)
        XCTAssertEqual(actual.width, chosen.width)
        XCTAssertEqual(actual.color.usingColorSpace(.sRGB), chosen.color.usingColorSpace(.sRGB))

        adapter.withSuppressedCallbacks { toolbar.selectedIndirectPointerTouchMode = .selection }
        adapter.markupToolbarViewControllerSelectedIndirectPointerTouchModeChanged(toolbar)
        XCTAssertFalse(editor.view.subviews.contains { $0 is AnnotationDrawingView })
        adapter.withSuppressedCallbacks { toolbar.selectedIndirectPointerTouchMode = .drawing }
        adapter.markupToolbarViewControllerSelectedIndirectPointerTouchModeChanged(toolbar)
        let resumed = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? AnnotationDrawingView }.first)
        XCTAssertEqual(resumed.inkingTool, chosen, "Returning to native drawing preserves the selected style")
    }

    @MainActor func testNestedSuppressionAndReentrantCommandsDoNotDispatchTwice() throws {
        _ = NSApplication.shared
        let canvas = PaperMarkupViewController(markup: PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 80, height: 60)), supportedFeatureSet: .latest)
        let toolbar = MarkupToolbarViewController(supportedFeatureSet: .latest)
        let adapter = NativeMarkupToolbarAdapter(canvas: canvas, toolbar: toolbar)
        var calls = 0
        adapter.onArrow = {
            calls += 1
            // Bound the recursion so a regression fails instead of overflowing.
            if calls < 3 {
                adapter.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
            }
        }
        defer { adapter.onArrow = nil }
        adapter.withSuppressedCallbacks {
            adapter.withSuppressedCallbacks {
                adapter.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
            }
            adapter.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
        }
        XCTAssertEqual(calls, 0)
        adapter.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
        XCTAssertEqual(calls, 1)
        enum Failure: Error { case expected }
        XCTAssertThrowsError(try adapter.withSuppressedCallbacks { throw Failure.expected })
        adapter.markupToolbarViewController(toolbar, insertNewLineWithStartMarker: false, endMarker: true)
        XCTAssertEqual(calls, 2, "Throwing must restore callback delivery")
    }
}
