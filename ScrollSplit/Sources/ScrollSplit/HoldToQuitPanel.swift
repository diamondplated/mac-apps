import AppKit
import SwiftUI
import ScrollSplitCore

/// A small centred panel that never takes focus or clicks: the frontmost app's icon in a
/// ring that fills while ⌘Q is held. Fades in and out; without Reduce Motion it also
/// settles from a slightly smaller size.
final class HoldToQuitPanel {
    private var panel: NSPanel?
    private var model: HoldToQuitModel?
    private static let fade = 0.15

    func show(for app: NSRunningApplication?) {
        let icon = app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let name = app?.localizedName ?? "App"
        let model = HoldToQuitModel(icon: icon, appName: name)
        self.model = model
        let hosting = NSHostingView(rootView: HoldToQuitView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? frame : frame.insetBy(dx: size.width * 0.03, dy: size.height * 0.03)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(frame, display: true) }
        }
        // The ring fills in exactly the hold time.
        DispatchQueue.main.async {
            withAnimation(.linear(duration: HoldToQuitGate.holdDuration)) { model.progress = 1 }
        }
    }

    func hide() {
        guard let panel else { return }
        model = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new hold may have started during the fade.
            guard let self, self.model == nil else { return }
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }

    /// Refuses key and main status outright, so the panel can never take focus.
    private final class UnfocusablePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static func makePanel() -> NSPanel {
        let panel = UnfocusablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        return panel
    }
}
