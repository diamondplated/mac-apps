import AppKit
import PaperKit
import PencilKit
import XCTest
@testable import ScreenWren

final class EditorLayoutTests: XCTestCase {
    @MainActor
    func testEditorKeepsToolsActionsAndStatusVisibleWhenResizing() throws {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 80, height: 60) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let status = String(repeating: "A detailed operation result. ", count: 12)
        let editor = EditorViewController(image: image, initialStatus: status) { _ in }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        defer { window.close() }
        let root = editor.view
        let header = try XCTUnwrap(root.subviews.first { $0 is NSVisualEffectView })
        let actions = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorFinishActions" } as? NSStackView)
        let quickTools = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorQuickTools" } as? NSStackView)
        let toolbar = try XCTUnwrap(header.subviews.first { !($0 is NSStackView) })
        let statusBar = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.first)
        let label = try XCTUnwrap(statusBar.views.compactMap { $0 as? NSTextField }.first)

        // Returning to each size exercises both directions across the breakpoint.
        for width: CGFloat in [720, 1040, 1440, 720, 1440] {
            window.setContentSize(CGSize(width: width, height: 720))
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.width, width, accuracy: 1)
            XCTAssertTrue(root.bounds.contains(header.frame))
            XCTAssertTrue(header.bounds.contains(toolbar.frame))
            XCTAssertTrue(header.bounds.contains(actions.frame))
            XCTAssertTrue(header.bounds.contains(quickTools.frame))
            XCTAssertFalse(toolbar.frame.intersects(actions.frame), "Tools overlap actions at \(width) points")
            XCTAssertFalse(toolbar.frame.intersects(quickTools.frame))
            XCTAssertFalse(actions.frame.intersects(quickTools.frame))
            if width == 720 { XCTAssertEqual(header.frame.height, 132, accuracy: 1) }
            if width == 1440 { XCTAssertEqual(header.frame.height, 92, accuracy: 1) }
            for button in (actions.views + quickTools.views).compactMap({ $0 as? NSButton }) {
                XCTAssertFalse(button.isHidden)
                XCTAssertGreaterThanOrEqual(button.bounds.width + 1, button.intrinsicContentSize.width)
                XCTAssertTrue(header.bounds.contains(button.convert(button.bounds, to: header)))
            }
            XCTAssertTrue(root.bounds.contains(statusBar.frame))
            XCTAssertGreaterThan(label.bounds.width, 600)
            XCTAssertEqual(label.stringValue, status)
            XCTAssertEqual(label.toolTip, status)
        }
        let inspect = try XCTUnwrap(actions.views.compactMap { $0 as? NSButton }.first { $0.title == "Inspect" })
        XCTAssertEqual(inspect.accessibilityLabel(), "Inspect image")
        XCTAssertEqual(inspect.keyEquivalent, "i")
        XCTAssertEqual(inspect.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor
    func testVisibleQuickToolsInsertMarkupAndSwitchDrawingModes() async throws {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 800, height: 600) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let editor = EditorViewController(image: image, initialStatus: "Ready") { _ in }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        defer { window.close() }
        editor.view.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(editor.view.subviews.first { $0 is NSVisualEffectView })
        let quickTools = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorQuickTools" } as? NSStackView)
        let buttons = quickTools.views.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map(\.title), ["Select", "Pen", "Arrow", "Box", "Text", "Highlight", "Step", "Crop", "Redact"])
        let markup = try XCTUnwrap(editor.children.compactMap { $0 as? PaperMarkupViewController }.first)
        let statusBar = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? NSStackView }.first)
        let status = try XCTUnwrap(statusBar.views.compactMap { $0 as? NSTextField }.first)
        for title in ["Text", "Step"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            let previousMarkup = try await markup.markup?.dataRepresentation()
            button.performClick(nil)
            let updatedMarkup = try await markup.markup?.dataRepresentation()
            XCTAssertNotEqual(updatedMarkup, previousMarkup, "\(title) must change the editable markup")
            XCTAssertTrue(status.stringValue.localizedCaseInsensitiveContains("inserted"), "\(title): \(status.stringValue)")
        }
        try XCTUnwrap(buttons.first { $0.title == "Highlight" }).performClick(nil)
        XCTAssertEqual(markup.indirectPointerTouchMode, .drawing)
        XCTAssertEqual((markup.drawingTool as? PKInkingTool)?.inkType, .marker)
        try XCTUnwrap(buttons.first { $0.title == "Pen" }).performClick(nil)
        XCTAssertEqual((markup.drawingTool as? PKInkingTool)?.inkType, .monoline)
        try XCTUnwrap(buttons.first { $0.title == "Select" }).performClick(nil)
        XCTAssertEqual(markup.indirectPointerTouchMode, .selection)
        XCTAssertTrue(buttons.allSatisfy { $0.toolTip?.isEmpty == false })
    }
}
