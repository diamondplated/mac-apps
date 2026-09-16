import Cocoa
import SwiftUI

final class TrackingContainerView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseMoved: (() -> Void)?
    var onMouseExited: (() -> Void)?
    
    private var trackingAreaRef: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}

public class PreviewPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var containerView: TrackingContainerView?
    
    public var onMouseEntered: (() -> Void)?
    public var onMouseMoved: (() -> Void)?
    public var onMouseExited: (() -> Void)?
    
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .popUpMenu
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.alphaValue = 0.0
        self.acceptsMouseMovedEvents = true
    }
    
    public override var canBecomeKey: Bool {
        return false
    }
    
    public override var canBecomeMain: Bool {
        return false
    }
    
    public func show(
        dockItem: HoveredDockItem,
        windows: [WindowInfo],
        onSelect: @escaping (WindowInfo) -> Void,
        onClose: @escaping (WindowInfo) -> Void
    ) {
        guard !windows.isEmpty else {
            hide()
            return
        }
        
        let screen = DockObserver.screen(for: dockItem.frame.origin)
        
        let view = PreviewView(
            appName: dockItem.title,
            appIcon: dockItem.icon,
            windows: windows,
            onSelectWindow: { [weak self] win in
                onSelect(win)
                self?.hide()
            },
            onCloseWindow: { win in
                onClose(win)
            }
        )
        
        // Calculate appropriate size
        let cardWidth: CGFloat = 222
        let spacing: CGFloat = 12
        let horizontalPadding: CGFloat = 24
        let totalWidth = min(
            CGFloat(windows.count) * cardWidth + CGFloat(max(0, windows.count - 1)) * spacing + horizontalPadding,
            screen.visibleFrame.width - 60
        )
        let totalHeight: CGFloat = 205
        let panelSize = NSSize(width: max(totalWidth, 240), height: totalHeight)
        
        let container = TrackingContainerView(frame: NSRect(origin: .zero, size: panelSize))
        container.onMouseEntered = { [weak self] in
            self?.onMouseEntered?()
        }
        container.onMouseMoved = { [weak self] in
            self?.onMouseMoved?()
        }
        container.onMouseExited = { [weak self] in
            self?.onMouseExited?()
        }
        
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        
        self.contentView = container
        self.containerView = container
        self.hostingView = hosting
        
        // Position panel adjacent to the Dock item based on orientation
        var origin = CGPoint.zero
        let dockRect = dockItem.frame
        
        switch dockItem.orientation {
        case .bottom:
            origin.x = dockRect.midX - (panelSize.width / 2.0)
            origin.y = dockRect.maxY + 14
            
            // Clamp within screen horizontal boundaries
            origin.x = max(screen.visibleFrame.minX + 16, min(origin.x, screen.visibleFrame.maxX - panelSize.width - 16))
            origin.y = min(origin.y, screen.visibleFrame.maxY - panelSize.height - 10)
            
        case .left:
            origin.x = dockRect.maxX + 14
            origin.y = dockRect.midY - (panelSize.height / 2.0)
            
            // Clamp within screen vertical boundaries
            origin.y = max(screen.visibleFrame.minY + 16, min(origin.y, screen.visibleFrame.maxY - panelSize.height - 16))
            origin.x = min(origin.x, screen.visibleFrame.maxX - panelSize.width - 10)
            
        case .right:
            origin.x = dockRect.minX - panelSize.width - 14
            origin.y = dockRect.midY - (panelSize.height / 2.0)
            
            // Clamp within screen vertical boundaries
            origin.y = max(screen.visibleFrame.minY + 16, min(origin.y, screen.visibleFrame.maxY - panelSize.height - 16))
            origin.x = max(origin.x, screen.visibleFrame.minX + 10)
        }
        
        self.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        self.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }
    
    public func hide() {
        guard self.alphaValue > 0 else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}
