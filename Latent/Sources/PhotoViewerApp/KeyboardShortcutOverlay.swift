import SwiftUI

/// Keyboard shortcut sheet, shown on `?` or Help > Keyboard Shortcuts. Any
/// key or click dismisses it.
struct KeyboardShortcutOverlay: View {
    @Binding var isPresented: Bool

    struct Shortcut: Hashable {
        let keys: String
        let action: String
    }

    struct Section: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    /// Kept in step with the README's culling and viewing sections and with
    /// the menu bar.
    static let sections: [Section] = [
        Section(title: "Navigation", shortcuts: [
            Shortcut(keys: "j  k", action: "Next / previous item"),
            Shortcut(keys: "→  ←", action: "Next / previous item"),
            Shortcut(keys: "Space", action: "Next item"),
            Shortcut(keys: "gg", action: "First item"),
            Shortcut(keys: "⇧G", action: "Last item"),
            Shortcut(keys: "⌘↑", action: "Enclosing folder"),
        ]),
        Section(title: "Culling", shortcuts: [
            Shortcut(keys: "⇧P", action: "Pick"),
            Shortcut(keys: "⇧X", action: "Reject"),
            Shortcut(keys: "1 – 9", action: "Color label"),
            Shortcut(keys: "0", action: "Clear label"),
            Shortcut(keys: "↩", action: "Keep best of burst"),
            Shortcut(keys: "⇧↩", action: "Keep this one"),
            Shortcut(keys: "⌫", action: "Move to Trash"),
            Shortcut(keys: "⌘Z", action: "Undo trash or keep"),
        ]),
        Section(title: "Selection", shortcuts: [
            Shortcut(keys: "⌘-click", action: "Add or remove"),
            Shortcut(keys: "⇧-click", action: "Select range"),
            Shortcut(keys: "⌘A", action: "Select all"),
            Shortcut(keys: "Esc", action: "Clear selection"),
            Shortcut(keys: "Esc Esc", action: "Close folder"),
        ]),
        Section(title: "Viewing", shortcuts: [
            Shortcut(keys: "Hold B", action: "Show original"),
            Shortcut(keys: "Double-click", action: "Zoom 2× → 3× → 4× → fit"),
            Shortcut(keys: "Pinch", action: "Zoom"),
            Shortcut(keys: "Drag", action: "Pan"),
            Shortcut(keys: "Space", action: "Play / pause video"),
            Shortcut(keys: "←  →", action: "Seek video 5 seconds"),
            Shortcut(keys: "↑  ↓", action: "Video volume"),
        ]),
        Section(title: "Window", shortcuts: [
            Shortcut(keys: "⌘O", action: "Open"),
            Shortcut(keys: "⌘F", action: "Search this folder"),
            Shortcut(keys: "⌘L", action: "Folder tree"),
            Shortcut(keys: "⌘E", action: "Enhancements"),
            Shortcut(keys: "⌘S", action: "Export enhanced copy"),
            Shortcut(keys: "⌘R", action: "Include subfolders"),
            Shortcut(keys: "⌘1  ⌘2", action: "Grid / map"),
            Shortcut(keys: "?", action: "This sheet"),
        ]),
    ]

    var body: some View {
        ZStack {
            // Dimmed background — click anywhere to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))

                HStack(alignment: .top, spacing: Theme.Spacing.section) {
                    column(Array(Self.sections.prefix(3)))
                    column(Array(Self.sections.suffix(from: 3)))
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: Theme.shape(Theme.Radius.panel))
            .overlay(Theme.shape(Theme.Radius.panel).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .onTapGesture { isPresented = false }
        }
        .onKeyPress(phases: .down) { _ in
            isPresented = false
            return .handled
        }
    }

    private func column(_ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            ForEach(sections) { section in
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.regular, verticalSpacing: 5) {
                    GridRow {
                        Text(section.title)
                            .font(.headline)
                            .gridCellColumns(2)
                    }
                    ForEach(section.shortcuts, id: \.self) { shortcut in
                        GridRow {
                            Text(shortcut.keys)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 96, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                            Text(shortcut.action)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }
}
