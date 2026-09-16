import SwiftUI
import Cocoa
import Combine

public class PreviewViewState: ObservableObject {
    @Published public var hoveredWindowID: CGWindowID? = nil
    
    public init() {}
}

public struct PreviewView: View {
    public let appName: String
    public let appIcon: NSImage?
    public let windows: [WindowInfo]
    public let onSelectWindow: (WindowInfo) -> Void
    public let onCloseWindow: (WindowInfo) -> Void
    
    @ObservedObject private var state = PreviewViewState()
    
    public init(
        appName: String,
        appIcon: NSImage?,
        windows: [WindowInfo],
        onSelectWindow: @escaping (WindowInfo) -> Void,
        onCloseWindow: @escaping (WindowInfo) -> Void
    ) {
        self.appName = appName
        self.appIcon = appIcon
        self.windows = windows
        self.onSelectWindow = onSelectWindow
        self.onCloseWindow = onCloseWindow
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: App Icon and Title
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(windows.count) window\(windows.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            
            // Window previews row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(windows) { win in
                        windowCard(for: win)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        )
    }
    
    @ViewBuilder
    private func windowCard(for win: WindowInfo) -> some View {
        let isHovered = state.hoveredWindowID == win.id
        
        VStack(spacing: 6) {
            // Window thumbnail area
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.25))
                        
                        if let thumb = win.thumbnail {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(6)
                                .padding(4)
                        } else if let icon = win.appIcon {
                            VStack(spacing: 8) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 48, height: 48)
                                Text(win.isMinimized ? "Minimized" : "No Preview Available")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if win.isMinimized {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 8, weight: .bold))
                            Text("Minimized")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(4)
                        .padding(6)
                    }
                }
                .frame(width: 210, height: 135)
                
                // Close button on hover
                if isHovered {
                    Button(action: {
                        onCloseWindow(win)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isHovered ? 2 : 1)
            )
            
            // Window title
            Text(win.title.isEmpty ? appName : win.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 200, alignment: .center)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                if hovering {
                    state.hoveredWindowID = win.id
                } else if state.hoveredWindowID == win.id {
                    state.hoveredWindowID = nil
                }
            }
        }
        .onTapGesture {
            onSelectWindow(win)
        }
    }
}
