import Cocoa
import SwiftUI

/// The centred, non-activating panel that shows the switcher's cards.
final class SwitcherPanel: NSPanel {
    private var presentationID = UUID()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The screen the user is working on: the one holding the keyboard focus.
    static var targetScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    static func layout(count: Int, on screen: NSScreen) -> SwitcherLayout {
        SwitcherLayout(count: count, availableSize: CGSize(
            width: (screen.visibleFrame.width * 0.9).rounded(.down),
            height: (screen.visibleFrame.height * 0.85).rounded(.down)
        ))
    }

    func show(model: SwitcherModel, onSelect: @escaping (Int) -> Void) {
        guard let screen = Self.targetScreen else { return }
        presentationID = UUID()
        let layout = Self.layout(count: model.entries.count, on: screen)
        model.columns = layout.columns
        let hosting = NSHostingView(rootView: SwitcherView(model: model, layout: layout, onSelect: onSelect))
        hosting.frame = NSRect(origin: .zero, size: layout.size)
        contentView = hosting
        let visible = screen.visibleFrame
        setFrame(NSRect(
            x: (visible.midX - layout.size.width / 2).rounded(),
            y: (visible.midY - layout.size.height / 2).rounded(),
            width: layout.size.width, height: layout.size.height
        ), display: true)
        orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        let dismissalID = UUID()
        presentationID = dismissalID
        guard isVisible else { return }
        guard alphaValue > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentationID == dismissalID else { return }
            self.orderOut(nil)
        })
    }
}
