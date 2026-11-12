import SwiftUI
import PhotoViewerCore

/// Active filter for the photo grid. Determines which subset of photos
/// are visible when applied to the full `imageURLs` list.
enum PhotoFilter: Equatable, Hashable, Identifiable {
    case all
    case picked
    case rejected
    case colorLabel(Int)  // 1-9

    var id: String {
        switch self {
        case .all: "all"
        case .picked: "picked"
        case .rejected: "rejected"
        case .colorLabel(let n): "color-\(n)"
        }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .picked: "Picked"
        case .rejected: "Rejected"
        case .colorLabel(let n): ColorLabel.name(n)
        }
    }

    /// The label number when this is a colour-label filter.
    var labelNumber: Int? {
        if case .colorLabel(let n) = self { return n }
        return nil
    }
}

/// Filter bar above the grid: All, Picked and Rejected as one segmented
/// control, plus a single Label menu for the nine colour labels.
struct FilterBar: View {
    @Binding var activeFilter: PhotoFilter
    let vimKeymap: VimKeymap
    let imageURLs: [URL]

    /// The segmented control's own selection. A colour-label filter selects
    /// no segment, so it maps to a tag none of the segments carry.
    private enum Segment: Hashable { case all, picked, rejected, none }

    var body: some View {
        let counts = filterCounts
        HStack(spacing: Theme.Spacing.small) {
            Picker("Show", selection: segmentBinding) {
                Text("All").tag(Segment.all)
                Text("Picked").tag(Segment.picked)
                Text("Rejected").tag(Segment.rejected)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("\(counts[.picked, default: 0]) picked, \(counts[.rejected, default: 0]) rejected")
            .accessibilityLabel("Show")

            labelMenu(counts: counts)

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
    }

    private var segmentBinding: Binding<Segment> {
        Binding(
            get: {
                switch activeFilter {
                case .all: .all
                case .picked: .picked
                case .rejected: .rejected
                case .colorLabel: .none
                }
            },
            set: { segment in
                switch segment {
                case .all: activeFilter = .all
                case .picked: activeFilter = .picked
                case .rejected: activeFilter = .rejected
                case .none: break
                }
            }
        )
    }

    private func labelMenu(counts: [PhotoFilter: Int]) -> some View {
        let active = activeFilter.labelNumber
        return Menu {
            ForEach(ColorLabel.all, id: \.self) { label in
                let count = counts[.colorLabel(label), default: 0]
                Toggle(isOn: Binding(
                    get: { active == label },
                    set: { activeFilter = $0 ? .colorLabel(label) : .all }
                )) {
                    Label {
                        Text(count > 0 ? "\(ColorLabel.name(label))  (\(count))" : ColorLabel.name(label))
                    } icon: {
                        ColorLabel.menuIcon(label)
                    }
                }
            }
            if active != nil {
                Divider()
                Button("Show All") { activeFilter = .all }
            }
        } label: {
            HStack(spacing: 5) {
                if let active {
                    Circle()
                        .fill(ColorLabel.color(active))
                        .frame(width: 8, height: 8)
                    Text(ColorLabel.name(active))
                } else {
                    Text("Label")
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Label filter")
        .accessibilityValue(active.map { ColorLabel.name($0) } ?? "Off")
    }

    /// Build every count in one pass. Large recursive folders can contain
    /// 100k items; filtering that list once per option on every keystroke
    /// makes a tiny status bar disproportionately expensive.
    private var filterCounts: [PhotoFilter: Int] {
        var counts: [PhotoFilter: Int] = [.all: imageURLs.count]
        for url in imageURLs {
            if vimKeymap.isPicked(url) { counts[.picked, default: 0] += 1 }
            if vimKeymap.isRejected(url) { counts[.rejected, default: 0] += 1 }
            let label = vimKeymap.colorLabel(for: url)
            if (1...9).contains(label) {
                counts[.colorLabel(label), default: 0] += 1
            }
        }
        return counts
    }
}

// MARK: - Filtering logic

extension PhotoFilter {
    /// Apply this filter to a URL list using the VimKeymap state.
    @MainActor
    func apply(to urls: [URL], keymap: VimKeymap) -> [URL] {
        switch self {
        case .all:
            return urls
        case .picked:
            return urls.filter { keymap.isPicked($0) }
        case .rejected:
            return urls.filter { keymap.isRejected($0) }
        case .colorLabel(let n):
            return urls.filter { keymap.colorLabel(for: $0) == n }
        }
    }
}

// MARK: - Filter-aware selection

extension AppState {
    var visibleImageURLs: [URL] {
        let culled = photoFilter.apply(to: imageURLs, keymap: vimKeymap)
        guard let searchResultURLs else { return culled }
        let allowed = Set(culled)
        // Preserve semantic rank rather than falling back to folder sort.
        return searchResultURLs.filter { allowed.contains($0) }
    }

    func selectNextVisible() {
        let urls = visibleImageURLs
        guard !urls.isEmpty else { return }
        guard let currentURL,
              let current = urls.firstIndex(of: currentURL) else {
            select(url: urls[0])
            return
        }
        select(url: urls[min(current + 1, urls.count - 1)])
    }

    func selectPreviousVisible() {
        let urls = visibleImageURLs
        guard !urls.isEmpty else { return }
        guard let currentURL,
              let current = urls.firstIndex(of: currentURL) else {
            select(url: urls[urls.count - 1])
            return
        }
        select(url: urls[max(current - 1, 0)])
    }

    func selectFirstVisible() {
        if let first = visibleImageURLs.first { select(url: first) }
    }

    func selectLastVisible() {
        if let last = visibleImageURLs.last { select(url: last) }
    }

    func selectAllVisible() {
        let urls = visibleImageURLs
        guard !urls.isEmpty else { return }
        multiSelection = Set(urls)
        if currentURL.map({ !urls.contains($0) }) ?? true {
            select(url: urls[0])
        }
    }
}
