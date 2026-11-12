import SwiftUI
import Cocoa

struct PreviewLayout {
    static let baseHeight: CGFloat = 224
    static let tabHeaderHeight: CGFloat = 34
    static let tabRowHeight: CGFloat = 32
    let size: CGSize
    let tabListHeight: CGFloat

    static func contentWidth(for window: WindowInfo) -> CGFloat {
        window.tabs.isEmpty ? 210 : 270
    }

    init(windows: [WindowInfo], availableSize: CGSize) {
        let maximumTabs = windows.map { $0.tabs.count }.max() ?? 0
        tabListHeight = min(
            CGFloat(min(maximumTabs, 5)) * Self.tabRowHeight,
            max(0, availableSize.height - Self.baseHeight - Self.tabHeaderHeight)
        )
        let width = windows.reduce(CGFloat(24)) { $0 + Self.contentWidth(for: $1) + 12 }
            + CGFloat(max(0, windows.count - 1)) * 12
        size = CGSize(
            width: min(max(width, 240), availableSize.width),
            height: min(Self.baseHeight + (maximumTabs > 0 ? Self.tabHeaderHeight + tabListHeight : 0), availableSize.height)
        )
    }
}

/// The suite's corner-radius scale: 6 for controls, 10 for cards, 14 for panels.
enum PreviewRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
}

func roundedShape(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

/// Short ease for anything that appears, disappears or changes state on hover.
func hoverEase(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
}

public struct PreviewView: View {
    public let appName: String
    public let appIcon: NSImage?
    public let windows: [WindowInfo]
    public let onSelectWindow: (WindowInfo) -> Void
    public let onCloseWindow: (WindowInfo) -> Void
    public let onSelectTab: (TabInfo, WindowInfo) -> Void
    private let tabListHeight: CGFloat
    @State private var hoveredWindowID: CGWindowID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        appName: String,
        appIcon: NSImage?,
        windows: [WindowInfo],
        tabListHeight: CGFloat = 160,
        onSelectWindow: @escaping (WindowInfo) -> Void,
        onCloseWindow: @escaping (WindowInfo) -> Void,
        onSelectTab: @escaping (TabInfo, WindowInfo) -> Void = { _, _ in }
    ) {
        self.appName = appName
        self.appIcon = appIcon
        self.windows = windows
        self.tabListHeight = tabListHeight
        self.onSelectWindow = onSelectWindow
        self.onCloseWindow = onCloseWindow
        self.onSelectTab = onSelectTab
    }

    private var countLabel: String {
        let tabs = windows.reduce(0) { $0 + $1.tabs.count }
        let windowCount = "\(windows.count) window\(windows.count == 1 ? "" : "s")"
        return tabs > 0 ? "\(windowCount) · \(tabs) tab\(tabs == 1 ? "" : "s")" : windowCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                Text(appName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(countLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(windows) { win in
                        windowCard(for: win)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            roundedShape(PreviewRadius.panel)
                .fill(.regularMaterial)
                .overlay(roundedShape(PreviewRadius.panel).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        )
        // The window draws the shadow, so nothing here is clipped by the panel bounds.
        .clipShape(roundedShape(PreviewRadius.panel))
    }

    private func windowCard(for win: WindowInfo) -> some View {
        let isHovered = hoveredWindowID == win.id
        let width = PreviewLayout.contentWidth(for: win)
        let title = win.title.isEmpty ? appName : win.title

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button { onSelectWindow(win) } label: {
                    VStack(spacing: 6) {
                        WindowThumbnail(window: win)
                            .frame(width: width, height: 135)
                            .overlay(
                                roundedShape(PreviewRadius.control)
                                    .strokeBorder(isHovered ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isHovered ? 2 : 1)
                            )
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isHovered ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: width - 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show window: \(title)")

                Button { onCloseWindow(win) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.primary, Color(nsColor: .windowBackgroundColor))
                        .font(.title3)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help("Close window")
                .accessibilityLabel("Close window")
                .padding(6)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
            }

            if !win.tabs.isEmpty {
                VStack(spacing: 6) {
                    Divider()
                    HStack {
                        Text("\(win.tabs.count) open tab\(win.tabs.count == 1 ? "" : "s")")
                        Spacer()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(win.tabs) { tab in
                                TabRow(tab: tab) { onSelectTab(tab, win) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(win.tabs.count) * PreviewLayout.tabRowHeight, tabListHeight))
                }
                .frame(width: width)
            }
        }
        .padding(6)
        .background(
            roundedShape(PreviewRadius.card)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .animation(hoverEase(reduceMotion), value: isHovered)
        .onHover { hovering in
            if hovering {
                hoveredWindowID = win.id
            } else if hoveredWindowID == win.id {
                hoveredWindowID = nil
            }
        }
    }
}

private struct TabRow: View {
    let tab: TabInfo
    let onSelect: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color {
        if isHovered { return Color.primary.opacity(0.08) }
        return tab.isSelected ? Color.accentColor.opacity(0.14) : Color.clear
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                // Only the active tab carries a mark; the rest align with it.
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(tab.isSelected ? 1 : 0)
                    .frame(width: 14)
                Text(tab.title)
                    .font(.subheadline.weight(tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: PreviewLayout.tabRowHeight)
            .background(fill, in: roundedShape(PreviewRadius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.fullTitle)
        .accessibilityLabel(tab.fullTitle)
        .accessibilityValue(tab.isSelected ? "Active tab" : "")
        .animation(hoverEase(reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
