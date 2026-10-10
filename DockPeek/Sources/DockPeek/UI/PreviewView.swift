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

public struct PreviewView: View {
    public let appName: String
    public let appIcon: NSImage?
    public let windows: [WindowInfo]
    public let onSelectWindow: (WindowInfo) -> Void
    public let onCloseWindow: (WindowInfo) -> Void
    public let onSelectTab: (TabInfo, WindowInfo) -> Void
    private let tabListHeight: CGFloat
    @State private var hoveredWindowID: CGWindowID?

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
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        )
    }

    private func windowCard(for win: WindowInfo) -> some View {
        let isHovered = hoveredWindowID == win.id
        let width = PreviewLayout.contentWidth(for: win)

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button { onSelectWindow(win) } label: {
                    VStack(spacing: 6) {
                        thumbnail(for: win)
                            .frame(width: width, height: 135)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isHovered ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isHovered ? 2 : 1)
                            )
                        Text(win.title.isEmpty ? appName : win.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isHovered ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: width - 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show window: \(win.title.isEmpty ? appName : win.title)")

                if isHovered {
                    Button { onCloseWindow(win) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help("Close window")
                    .accessibilityLabel("Close window")
                    .padding(6)
                }
            }

            if !win.tabs.isEmpty {
                VStack(spacing: 6) {
                    Divider()
                    HStack {
                        Text("\(win.tabs.count) open tab\(win.tabs.count == 1 ? "" : "s")")
                        Spacer()
                        Image(systemName: "rectangle.on.rectangle")
                    }
                    .font(.system(size: 10, weight: .medium))
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
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            if hovering {
                hoveredWindowID = win.id
            } else if hoveredWindowID == win.id {
                hoveredWindowID = nil
            }
        }
    }

    private func thumbnail(for win: WindowInfo) -> some View {
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
                } else {
                    VStack(spacing: 8) {
                        if let icon = win.appIcon {
                            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                        }
                        Text(win.isMinimized ? "Minimized" : "No Preview Available")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if win.isMinimized {
                Label("Minimized", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }
}

private struct TabRow: View {
    let tab: TabInfo
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Image(systemName: tab.isSelected ? "checkmark.circle.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(tab.isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                Text(tab.title)
                    .font(.system(size: 11, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: PreviewLayout.tabRowHeight)
            .background(
                isHovered ? Color.primary.opacity(0.1) : (tab.isSelected ? Color.accentColor.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.fullTitle)
        .accessibilityLabel(tab.fullTitle)
        .accessibilityValue(tab.isSelected ? "Active tab" : "")
        .onHover { isHovered = $0 }
    }
}
