import SiftEngine
import SwiftUI

// The SQL box: a monospaced editor, a status line, `Run ⌘↵` and `Reset to Filters`.
//
// 🔴 **THIS FILE CONTAINS NO SQL AND NO VALIDATION, AND THAT IS THE POINT.** SQL mode is the one
// place a user's own text reaches the database. The SELECT-only gate is `SiftEngine`'s
// (`assertSelectOnly`, run first by `Session.runSQL` and again by `export` on the stored text), and
// it has been attacked hard and holds: multi-statement text, a leading COPY/ATTACH/INSTALL/CREATE,
// comment-hidden second statements, paren and format-string breakouts, embedded nulls and quote
// injection in paths and table names all refuse, with nothing written outside the destination. The
// enforcement underneath the message is grammar-level — `wrapUserSQL`'s newline subquery wrap, in
// which a non-SELECT cannot occupy a subquery position.
//
// So this view does exactly three things with the user's text: show it, hand it unmodified to
// `TableViewModel.runSQL()`, and show whatever sentence comes back. It adds no keyword check of its
// own (a second, weaker gate in the UI is how a blocklist becomes the thing people trust), it does
// not pre-validate and then send something else, and it does not `try?` an engine error away or
// re-word it — the guard reports one clean sentence and this project has broken that contract four
// times already.
//
// One consequence worth stating because it reads like a bug: `SELECT * FROM nonexistent` is NOT
// refused here. It fails to *prepare*, which is a query-path error about a table the user has not
// opened, not a guard rejection (GuardStatements.swift's landmine note). The engine lets it
// through and reports the catalog error; so does this.

/// The console's status line, which is also the one-way-door warning.
///
/// Two states and no third. `owned` is
/// `TableViewModel.sqlOwned`: the user has typed in the box, so the filters and the header controls
/// no longer describe what the grid is showing, and nothing will try to parse their SQL back into
/// filters to make them again. `Reset to filters` is the only way back, and this sentence is what
/// tells them before they find out.
public func sqlStatusText(owned: Bool) -> String {
    owned ? "your SQL — filters and header controls are frozen" : "mirrors the filters above"
}

/// The SQL box for one open table.
public struct SQLConsole: View {
    private let model: TableViewModel
    private let onError: (String) -> Void

    public init(model: TableViewModel, onError: @escaping (String) -> Void) {
        self.model = model
        self.onError = onError
    }

    /// Routed through `typeSQL` rather than binding `sqlText` directly: the setter is what claims
    /// the box, and the model's mirror must be able to write the same property without claiming it.
    private var text: Binding<String> {
        Binding(get: { model.sqlText }, set: { model.typeSQL($0) })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The editor sits on the system text-background colour in a hairline-bordered box, so it
            // follows light and dark mode like any other text field.
            TextEditor(text: text)
                .font(.siftMono)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                .frame(minHeight: 76, maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle.sift())
                .overlay(RoundedRectangle.sift().strokeBorder(Color(nsColor: .separatorColor)))

            HStack(spacing: 8) {
                Text(sqlStatusText(owned: model.sqlOwned))
                    .font(model.sqlOwned ? .siftCaptionStrong : .siftCaption)
                    .foregroundStyle(model.sqlOwned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    // The one-way-door warning is the whole reason the line exists; an elided one
                    // stops being a warning.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Reset to Filters") {
                    Task { await report { try await model.exitSQLMode() } }
                }
                Button {
                    Task { await report { try await model.runSQL() } }
                } label: {
                    // The shortcut is spelled out because it is the only way to run without leaving
                    // the editor, and `.keyboardShortcut` draws nothing itself.
                    Text("Run \u{2318}\u{21A9}")
                }
                // 🔴 On the BUTTON, not on the editor. A `TextEditor` swallows Return, and there is
                // no key handler to hang ⌘↵ off; a button's shortcut is dispatched by the window
                // regardless of what holds focus, which is what makes ⌘↵ work while the user is
                // still typing.
                .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        // `id:` so switching tabs re-mirrors against the newly selected table, and the error is
        // surfaced rather than swallowed — `RootView`'s own `.task(id:)` makes the same call.
        .task(id: model.name) {
            await report { try await model.mirrorRenderedSQL() }
        }
    }

    /// Whatever the engine threw, as its own sentence. Not re-worded, not summarised, not
    /// swallowed: `SessionError`/`SQLRejected` are already one clean user-facing sentence each, and
    /// every layer that has tried to improve on them here has made them worse.
    private func report(_ work: () async throws -> Void) async {
        do { try await work() } catch { onError(error.localizedDescription) }
    }
}
