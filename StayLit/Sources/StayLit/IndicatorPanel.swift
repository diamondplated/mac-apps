import AppKit
import SwiftUI
import StayLitCore

/// Shows the indicator near the top-right of the display that changed, then fades it out.
final class IndicatorPanel {
    private var panel: NSPanel?
    private var hosting: NSHostingView<IndicatorView>?
    private var hideWork: DispatchWorkItem?

    func show(_ model: IndicatorModel, on displayID: UInt32) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let panel = self.panel ?? makePanel()
        if let hosting { hosting.rootView = IndicatorView(model: model) }
        let size = IndicatorView.size
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
        }
        fade(panel, to: 1, reduceMotion: reduceMotion)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let panel else { return }
            self?.fade(panel, to: 0, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, reduceMotion: Bool, completion: (() -> Void)? = nil) {
        guard !reduceMotion else { panel.alphaValue = alpha; completion?(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            // A key press during the fade-out brings it back; only order out if it stayed hidden.
            if panel.alphaValue == alpha { completion?() }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: IndicatorView.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: IndicatorView(model: IndicatorModel(kind: .brightness, level: 0, displayName: "")))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}
