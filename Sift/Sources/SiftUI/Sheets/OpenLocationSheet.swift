import SwiftUI

/// File > Open Location…: one box for a path or a URL.
///
/// It opens through `AppState.open(paths:)`, the entry the open panel, the Dock icon, Finder's Open
/// With and a window drop all use, so a pasted workbook reaches the sheet picker by the one route
/// that decides that. A pasted path or URL (more than one character arriving at once) opens by
/// itself, as `autoOpenPath` decides; typing never does.
struct OpenLocationSheet: View {
    /// Called with the chosen path after the sheet asks to close; the presenter opens it once the
    /// sheet is gone, so a workbook picker or an extension alert is not raised over a closing sheet.
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Location").font(.siftTitle)
            TextField("Path or URL", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: text) { old, new in
                    guard let path = autoOpenPath(from: old, to: new) else { return }
                    open(path)
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        open(trimmed)
    }

    private func open(_ path: String) {
        onOpen(path)
        dismiss()
    }
}
