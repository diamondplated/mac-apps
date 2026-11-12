import SwiftUI
import Cocoa

/// What the switcher panel shows. Thumbnails fill in as captures arrive.
final class SwitcherModel: ObservableObject {
    @Published var entries: [SwitcherEntry] = []
    @Published var highlight: Int?
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var columns = 1
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let layout: SwitcherLayout
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(SwitcherLayout.cardSize.width), spacing: SwitcherLayout.spacing), count: layout.columns),
                    spacing: SwitcherLayout.spacing
                ) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        Button { onSelect(index) } label: {
                            SwitcherCard(
                                entry: entry,
                                thumbnail: model.thumbnails[entry.candidate.id],
                                isHighlighted: model.highlight == index
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(SwitcherLayout.inset)
            }
            .scrollDisabled(!layout.scrolls)
            .scrollIndicators(layout.scrolls ? .automatic : .hidden)
            .onAppear {
                // After the first layout pass; scrolling during it is ignored.
                guard layout.scrolls, let highlight = model.highlight else { return }
                DispatchQueue.main.async { proxy.scrollTo(highlight, anchor: .center) }
            }
            .onChange(of: model.highlight) { _, highlight in
                guard layout.scrolls, let highlight else { return }
                withAnimation(hoverEase(reduceMotion)) { proxy.scrollTo(highlight) }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(
            roundedShape(PreviewRadius.panel)
                .fill(.regularMaterial)
                .overlay(roundedShape(PreviewRadius.panel).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        )
        .clipShape(roundedShape(PreviewRadius.panel))
    }
}

private struct SwitcherCard: View {
    let entry: SwitcherEntry
    let thumbnail: NSImage?
    let isHighlighted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            WindowThumbnail(thumbnail: thumbnail, appIcon: entry.appIcon, isMinimized: entry.candidate.isMinimized, iconSize: 56, showsNoPreviewLabel: false)
                .frame(width: SwitcherLayout.thumbnailSize.width, height: SwitcherLayout.thumbnailSize.height)
                .overlay(
                    roundedShape(PreviewRadius.control)
                        .strokeBorder(isHighlighted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isHighlighted ? 3 : 1)
                )
            HStack(spacing: 6) {
                if let icon = entry.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(entry.title)
                    .font(.subheadline.weight(isHighlighted ? .semibold : .medium))
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(width: SwitcherLayout.thumbnailSize.width, height: SwitcherLayout.titleHeight)
        }
        .padding(SwitcherLayout.cardPadding)
        .background(
            roundedShape(PreviewRadius.card)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(roundedShape(PreviewRadius.card))
        .animation(hoverEase(reduceMotion), value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.appName), \(entry.title)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
