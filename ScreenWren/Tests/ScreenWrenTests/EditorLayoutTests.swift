import AppKit
import PaperKit
import PencilKit
import XCTest
@testable import ScreenWren

final class EditorLayoutTests: XCTestCase {
    /// macOS 27's canvas drops a visible-frame request made before it finishes setting up, which
    /// left new captures at 100% zoom, spilling over the toolbar instead of fitting the window.
    @MainActor
    func testNewEditorFitsAndClipsACaptureLargerThanItsCanvas() async throws {
        _ = NSApplication.shared
        let image = try renderCGImage(width: 863, height: 739) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 863, height: 739))
        }
        let controller = EditorWindowController(image: image, copied: true) { _ in }
        defer { controller.close() }
        let editor = try XCTUnwrap(controller.contentViewController as? EditorViewController)
        controller.showWindow(nil)
        let canvas = try XCTUnwrap(editor.children.compactMap { $0 as? PaperMarkupViewController }.first)
        XCTAssertTrue(canvas.view.clipsToBounds, "The canvas must not draw over the header or status bar")

        let imageBounds = CGRect(x: 0, y: 0, width: 863, height: 739)
        let deadline = Date().addingTimeInterval(5)
        while !canvas.contentVisibleFrame.contains(imageBounds), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(canvas.contentVisibleFrame.contains(imageBounds),
                      "Whole capture must be visible, got \(canvas.contentVisibleFrame)")
    }

    @MainActor
    private func headerParts(_ editor: EditorViewController) throws
        -> (header: NSView, row: NSStackView, groups: [String: NSStackView])
    {
        let header = try XCTUnwrap(editor.view.subviews.first { $0.identifier?.rawValue == "editorHeader" })
        let row = try XCTUnwrap(header.subviews.first { $0.identifier?.rawValue == "editorHeaderRow" } as? NSStackView)
        var groups: [String: NSStackView] = [:]
        for case let group as NSStackView in row.views { groups[group.identifier?.rawValue ?? ""] = group }
        return (header, row, groups)
    }

    @MainActor
    func testEditorHeaderIsOneRowThatKeepsEveryControlVisibleWhenResizing() throws {
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
        let (header, row, groups) = try headerParts(editor)
        XCTAssertNil(header.subviews.first { $0.identifier?.rawValue == "editorQuickTools" },
                     "The labeled quick-tools row is gone")
        let imageTools = try XCTUnwrap(groups["editorImageTools"])
        let inspectTools = try XCTUnwrap(groups["editorInspectTools"])
        let actions = try XCTUnwrap(groups["editorFinishActions"])
        let toolbar = try XCTUnwrap(row.views.first { !($0 is NSStackView) && !($0 is NSBox) })
        let statusBar = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.first)
        let label = try XCTUnwrap(statusBar.views.compactMap { $0 as? NSTextField }.first)

        // Returning to each size exercises both directions.
        for width: CGFloat in [720, 1040, 1440, 720] {
            window.setContentSize(CGSize(width: width, height: 720))
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.width, width, accuracy: 1)
            XCTAssertEqual(header.frame.height, 52, accuracy: 1, "The header never wraps to a second row")
            XCTAssertTrue(root.bounds.contains(header.frame))
            let parts: [NSView] = [toolbar, imageTools, inspectTools, actions]
            for (index, part) in parts.enumerated() {
                let frame = part.convert(part.bounds, to: header)
                XCTAssertTrue(header.bounds.contains(frame), "Part \(index) leaves the header at \(width) points")
                for other in parts[(index + 1)...] {
                    XCTAssertFalse(frame.intersects(other.convert(other.bounds, to: header)),
                                   "Header parts overlap at \(width) points")
                }
            }
            for button in (imageTools.views + inspectTools.views + actions.views).compactMap({ $0 as? NSButton }) {
                XCTAssertFalse(button.isHidden)
                XCTAssertTrue(header.bounds.contains(button.convert(button.bounds, to: header)))
                XCTAssertFalse(button.toolTip?.isEmpty ?? true, "Every header control has a tooltip")
                XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true, "Every header control has a spoken name")
            }
            XCTAssertTrue(root.bounds.contains(statusBar.frame))
            XCTAssertGreaterThan(label.bounds.width, 600)
            XCTAssertEqual(label.stringValue, status)
            XCTAssertEqual(label.toolTip, status)
        }
        let titled = (imageTools.views + inspectTools.views + actions.views)
            .compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
        XCTAssertEqual(titled.map(\.title), ["Copy"], "Copy is the header's one labeled, primary action")
        let inspect = try XCTUnwrap(inspectTools.views.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Inspect image" })
        XCTAssertEqual(inspect.keyEquivalent, "i")
        XCTAssertEqual(inspect.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor
    func testHeaderImageToolsAndToolKeysInsertMarkupAndSwitchDrawingModes() async throws {
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
        let imageTools = try XCTUnwrap(try headerParts(editor).groups["editorImageTools"])
        let buttons = imageTools.views.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() ?? "" }, ["Crop", "Redact", "Step"])
        let markup = try XCTUnwrap(editor.children.compactMap { $0 as? PaperMarkupViewController }.first)
        let statusBar = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? NSStackView }.first)
        let status = try XCTUnwrap(statusBar.views.compactMap { $0 as? NSTextField }.first)

        var previousMarkup = try await markup.markup?.dataRepresentation()
        try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Step" }).performClick(nil)
        var updatedMarkup = try await markup.markup?.dataRepresentation()
        XCTAssertNotEqual(updatedMarkup, previousMarkup, "Step must change the editable markup")
        XCTAssertTrue(status.stringValue.localizedCaseInsensitiveContains("inserted"), status.stringValue)

        previousMarkup = updatedMarkup
        editor.performEditorCommand(.text)
        updatedMarkup = try await markup.markup?.dataRepresentation()
        XCTAssertNotEqual(updatedMarkup, previousMarkup, "T must still insert a text box")

        editor.performEditorCommand(.highlighter)
        XCTAssertEqual((markup.drawingTool as? PKInkingTool)?.inkType, .marker)
        editor.performEditorCommand(.escape)
        editor.performEditorCommand(.escape)
        XCTAssertEqual(markup.indirectPointerTouchMode, .selection)
    }
}
