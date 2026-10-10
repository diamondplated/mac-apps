import AppKit
import Carbon.HIToolbox
import PaperKit
import XCTest

@testable import ScreenWren

final class AnnotationDrawingTests: XCTestCase {
    @MainActor private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView,
                                 modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor private func drag(_ view: AnnotationDrawingView, from start: CGPoint, to end: CGPoint,
                                modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try XCTUnwrap(view.window)
        let root = try XCTUnwrap(window.contentView)
        XCTAssertTrue(root.hitTest(view.convert(start, to: root)) === view,
                      "The drawing overlay must receive an actual canvas click")
        window.sendEvent(try mouse(.leftMouseDown, point: start, in: view))
        window.sendEvent(try mouse(.leftMouseDragged, point: end, in: view, modifiers: modifiers))
        window.sendEvent(try mouse(.leftMouseUp, point: end, in: view, modifiers: modifiers))
    }

    private func redPixels(_ image: CGImage, in rectangle: CGRect) throws -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in Int(rectangle.minY)..<Int(rectangle.maxY) {
            for x in Int(rectangle.minX)..<Int(rectangle.maxX) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.65 && color.greenComponent < 0.45 && color.blueComponent < 0.45 { count += 1 }
            }
        }
        return count
    }

    @MainActor func testDirectionalArrowGestureSnapsAndClipsWithoutInsertingOnClickOrEscape() throws {
        _ = NSApplication.shared
        let overlay = AnnotationDrawingView(frame: CGRect(x: 0, y: 0, width: 200, height: 120), tool: .arrow)
        let window = NSWindow(contentRect: overlay.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = overlay
        window.orderFrontRegardless()
        defer { window.close() }
        overlay.interactionBounds = CGRect(x: 10, y: 10, width: 170, height: 100)
        var gestures: [AnnotationGesture] = []
        var cancellations = 0
        overlay.onFinish = { if let gesture = $0 { gestures.append(gesture) } else { cancellations += 1 } }
        try drag(overlay, from: CGPoint(x: 160, y: 45), to: CGPoint(x: 40, y: 46), modifiers: .shift)
        guard gestures.count == 1 else { XCTFail("The window did not deliver the arrow gesture"); return }
        XCTAssertEqual(gestures[0].start, CGPoint(x: 160, y: 45))
        XCTAssertEqual(gestures[0].end.y, 45, accuracy: 0.001)
        XCTAssertLessThan(gestures[0].end.x, gestures[0].start.x, "The tip must follow a right-to-left drag")
        try drag(overlay, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200))
        XCTAssertEqual(gestures.last?.end, CGPoint(x: 180, y: 110))
        try drag(overlay, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(gestures.count, 2)
        overlay.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Escape))))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(gestures.count, 2)
    }

    @MainActor func testArrowAndBoxDrawIntoExportAndUndoRestoresOriginalPixels() async throws {
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
        for title in ["Arrow", "Box"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            let hit = editor.view.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: editor.view))
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                          "The visible \(title) button must receive an actual click")
            button.performClick(nil)
            let overlay = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? AnnotationDrawingView }.first)
            if title == "Box" {
                for width: CGFloat in [720, 1440, 1040] {
                    window.setContentSize(CGSize(width: width, height: 720))
                    editor.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(overlay.frame, canvas.view.frame, "Drawing must follow the resized canvas")
                }
                canvas.setContentVisibleFrame(CGRect(x: 20, y: 30, width: 260, height: 200), animated: false)
                editor.view.layoutSubtreeIfNeeded()
            }
            let start = imageView.convert(CGPoint(x: 40, y: 60), to: overlay)
            let end = imageView.convert(CGPoint(x: 180, y: 100), to: overlay)
            try drag(overlay, from: start, to: end)
            XCTAssertFalse(editor.view.subviews.contains { $0 is AnnotationDrawingView })
            let rendered = try await editor.renderEditedImage()
            XCTAssertGreaterThan(try redPixels(rendered, in: CGRect(x: 30, y: 190, width: 165, height: 60)), 150,
                                 "Native annotations must render where the user dragged")
            XCTAssertEqual(try redPixels(rendered, in: CGRect(x: 30, y: 50, width: 165, height: 60)), 0,
                           "Annotation coordinates must not mirror the drag vertically")
            if title == "Arrow" {
                let tip = try redPixels(rendered, in: CGRect(x: 168, y: 188, width: 24, height: 24))
                let tail = try redPixels(rendered, in: CGRect(x: 28, y: 228, width: 24, height: 24))
                XCTAssertGreaterThan(tip, tail, "The dragged endpoint must include an arrowhead")
            }
            XCTAssertEqual(window.undoManager?.undoActionName, title)
            window.undoManager?.undo()
            let undone = try await editor.renderEditedImage()
            XCTAssertEqual(try redPixels(undone, in: CGRect(x: 0, y: 0, width: 400, height: 300)), 0)
            window.undoManager?.redo()
            let redone = try await editor.renderEditedImage()
            XCTAssertGreaterThan(try redPixels(redone, in: CGRect(x: 30, y: 190, width: 165, height: 60)), 150)
            window.undoManager?.undo()
        }
        let beforeCancel = try await canvas.markup?.dataRepresentation()
        try XCTUnwrap(buttons.first { $0.title == "Arrow" }).performClick(nil)
        let select = try XCTUnwrap(buttons.first { $0.title == "Select" })
        XCTAssertTrue(select.isEnabled)
        select.performClick(nil)
        XCTAssertFalse(editor.view.subviews.contains { $0 is AnnotationDrawingView })
        let afterCancel = try await canvas.markup?.dataRepresentation()
        XCTAssertEqual(beforeCancel, afterCancel, "Select cancels drawing without adding markup")
        XCTAssertTrue(buttons.allSatisfy(\.isEnabled))
    }
}
