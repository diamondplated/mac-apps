import SwiftUI
import Cocoa

/// A window's thumbnail, or its app icon when there is none, with the minimized badge.
/// Shared by the Dock preview and the window switcher.
struct WindowThumbnail: View {
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let isMinimized: Bool
    var iconSize: CGFloat = 48
    var showsNoPreviewLabel = true

    init(window: WindowInfo) {
        thumbnail = window.thumbnail
        appIcon = window.appIcon
        isMinimized = window.isMinimized
    }

    init(thumbnail: NSImage?, appIcon: NSImage?, isMinimized: Bool, iconSize: CGFloat = 48, showsNoPreviewLabel: Bool = true) {
        self.thumbnail = thumbnail
        self.appIcon = appIcon
        self.isMinimized = isMinimized
        self.iconSize = iconSize
        self.showsNoPreviewLabel = showsNoPreviewLabel
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                roundedShape(PreviewRadius.control)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(roundedShape(PreviewRadius.control))
                        .padding(4)
                } else {
                    VStack(spacing: 8) {
                        if let appIcon {
                            Image(nsImage: appIcon).resizable().frame(width: iconSize, height: iconSize)
                        }
                        if showsNoPreviewLabel {
                            Text("No Preview")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isMinimized {
                Label("Minimized", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: roundedShape(PreviewRadius.control))
                    .overlay(roundedShape(PreviewRadius.control).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                    .padding(6)
            }
        }
    }
}
