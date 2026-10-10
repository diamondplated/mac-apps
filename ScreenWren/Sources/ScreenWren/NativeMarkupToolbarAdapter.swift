import AppKit
import PaperKit
import PencilKit

/// Keeps the native style toolbar and the editor's explicit drawing tools on the
/// same command path, while preserving PaperKit's remaining native commands.
@MainActor
final class NativeMarkupToolbarAdapter: @preconcurrency MarkupToolbarViewController.Delegate {
    var onArrow: (() -> Void)?
    var onRectangle: (() -> Void)?
    var onText: (() -> Void)?
    var onInkingTool: ((PKInkingTool) -> Void)?
    var onSelection: (() -> Void)?

    /// Dismiss any custom drawing overlay before native handling. Return false
    /// when a sheet or pending image operation must retain ownership of input.
    var onPrepareNativeCommand: (() -> Bool)?

    private let canvas: PaperMarkupViewController
    private let toolbar: MarkupToolbarViewController
    private var suppressionDepth = 0

    init(canvas: PaperMarkupViewController, toolbar: MarkupToolbarViewController) {
        self.canvas = canvas
        self.toolbar = toolbar
    }

    /// Use when updating toolbar properties from editor actions. Delegate
    /// dispatch also uses this guard because callbacks can update those same
    /// properties synchronously.
    @discardableResult
    func withSuppressedCallbacks<Result>(_ body: () throws -> Result) rethrows -> Result {
        suppressionDepth += 1
        defer { suppressionDepth -= 1 }
        return try body()
    }

    private func dispatch(_ body: () -> Void) {
        guard suppressionDepth == 0 else { return }
        withSuppressedCallbacks(body)
    }

    private func forwardNative(_ body: () -> Void) {
        guard onPrepareNativeCommand?() != false else { return }
        body()
    }

    func markupToolbarViewController(
        _ markupToolbarViewController: MarkupToolbarViewController,
        insertNewShape type: ShapeConfiguration.Shape
    ) {
        dispatch {
            if type == .rectangle, let onRectangle {
                onRectangle()
            } else {
                forwardNative { canvas.markupToolbarViewController(toolbar, insertNewShape: type) }
            }
        }
    }

    func markupToolbarViewControllerInsertNewTextbox(_ markupToolbarViewController: MarkupToolbarViewController) {
        dispatch {
            if let onText {
                onText()
            } else {
                forwardNative { canvas.markupToolbarViewControllerInsertNewTextbox(toolbar) }
            }
        }
    }

    func markupToolbarViewController(
        _ markupToolbarViewController: MarkupToolbarViewController,
        insertNewLineWithStartMarker lineStartMarker: Bool,
        endMarker lineEndMarker: Bool
    ) {
        dispatch {
            if !lineStartMarker, lineEndMarker, let onArrow {
                onArrow()
            } else {
                // Preserve unadorned, reversed, and double-ended lines.
                forwardNative {
                    canvas.markupToolbarViewController(
                        toolbar, insertNewLineWithStartMarker: lineStartMarker, endMarker: lineEndMarker)
                }
            }
        }
    }

    func markupToolbarViewController(
        _ markupToolbarViewController: MarkupToolbarViewController,
        insertNewContents toInsert: PaperMarkup
    ) {
        dispatch {
            forwardNative { canvas.markupToolbarViewController(toolbar, insertNewContents: toInsert) }
        }
    }

    func markupToolbarViewControllerSelectedIndirectPointerTouchModeChanged(_ toolbar: MarkupToolbarViewController) {
        dispatch {
            if toolbar.selectedIndirectPointerTouchMode == .selection, let onSelection {
                onSelection()
            } else if toolbar.selectedIndirectPointerTouchMode == .drawing,
                      let tool = toolbar.selectedDrawingTool as? PKInkingTool,
                      let onInkingTool {
                onInkingTool(tool)
            } else {
                forwardNative { canvas.markupToolbarViewControllerSelectedIndirectPointerTouchModeChanged(toolbar) }
            }
        }
    }

    func markupToolbarViewControllerSelectedDrawingToolChanged(_ toolbar: MarkupToolbarViewController) {
        dispatch {
            if toolbar.selectedIndirectPointerTouchMode == .drawing,
               let tool = toolbar.selectedDrawingTool as? PKInkingTool, let onInkingTool {
                onInkingTool(tool)
            } else {
                // Eraser, lasso, and future native tools keep PaperKit behavior.
                forwardNative { canvas.markupToolbarViewControllerSelectedDrawingToolChanged(toolbar) }
            }
        }
    }
}
