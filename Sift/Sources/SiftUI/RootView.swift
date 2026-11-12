import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

/// The window's whole contents: sources on the left, the open table on the right.
public struct RootView: View {
    @Bindable private var state: AppState
    private let onOpen: () -> Void

    /// Whether the SQL console is showing. Per window and not per table — `sqlwrap`'s `display` was
    /// one element for the whole page, and a toggle that forgot itself on
    /// every tab switch would be worse than one that remembers the wrong thing.
    @State private var showSQL = false
    @State private var afterSheetDismissal: (@MainActor () async -> Void)?

    public init(state: AppState, onOpen: @escaping () -> Void) {
        self.state = state
        self.onOpen = onOpen
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SourceSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
        } detail: {
            // Banners, filter bar, console, grid, in that order. The banners sit
            // ABOVE the toolbar because several of them (staging, a missing extension) are about the
            // engine rather than about this view of the table, and pushing them under the filters
            // would read as though the filters caused them.
            VStack(spacing: 0) {
                if let table = state.active, let model = state.model(for: table.name) {
                    // One surface for everything above the grid, so banners, filters and the SQL
                    // console read as a single toolbar region with one rule under it, not as
                    // separate strips.
                    VStack(spacing: 0) {
                        BannerStack(state: state)
                        FilterBar(model: model, showSQL: $showSQL) { state.banner = $0 }
                        if showSQL {
                            SQLConsole(model: model) { state.banner = $0 }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(.bar)
                    .clipped()
                    Divider()
                    TableGrid(
                        model: model,
                        onColumnSelected: { state.selectedColumn = $0 },
                        onFilterColumn: {
                            state.selectedColumn = $0
                            state.inspectorVisible = true
                        },
                        onCopyAs: { dialect in Task { await state.copySnippet(dialect) } },
                        onError: { state.banner = $0 })
                } else {
                    BannerStack(state: state)
                    NothingOpenYet(onOpen: onOpen)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = state.toast {
                    Text(toast)
                        .font(.siftLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle.sift())
                        .overlay(RoundedRectangle.sift().strokeBorder(Color(nsColor: .separatorColor)))
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .siftAnimation(value: state.toast)
            // 🔴 **`.toolbar` HERE, and not an `NSToolbarDelegate` in `SiftApp`.** Task 13 measured
            // the reason and then had to work around it: `NavigationSplitView` inside an
            // `NSHostingView` REPLACES `window.toolbar` with an `NSToolbar` of its own, whose
            // delegate is `SwiftUI.ToolbarPlatformDelegate`. The shell's
            // `toolbarDefaultItemIdentifiers` was called and its items were built — and then the
            // whole toolbar was swapped out from under them, so Open and the row count ended up in
            // an `NSTitlebarAccessoryViewController` (the one strip SwiftUI does not manage) with
            // its frame re-fitted by hand on every catalog change.
            //
            // 🔴 **On the DETAIL column, not on the `NavigationSplitView`.** MEASURED against the
            // running app, 1480 pt wide with room to spare: attached to the split view, every
            // trailing item was pushed into the "more toolbar items" overflow popup and Merge landed
            // at x=215 — inside the sidebar's own toolbar region, ahead of the sidebar toggle. The
            // split view's toolbar is divided per column, so `.primaryAction` there is trailing OF
            // THE SIDEBAR. Attached to the detail column the same items lay out at x=1473/1510/1547,
            // at the window's trailing edge, with no overflow.
            //
            // The bare `NSToolbar` assigned at window creation must stay: `.fullSizeContentView`
            // needs a toolbar to exist at t=0 or the content view covers the title bar, swallows
            // every mouse event and the window cannot be moved at all. SwiftUI replaces it a moment
            // later with this one.
            .toolbar { toolbarItems }
        }
        .inspector(isPresented: $state.inspectorVisible) { InspectorView(state: state) }
        // The whole window is the drop target. It publishes `\.sourceDragHot`, which is how the
        // sidebar's dropzone and the empty state below both learn that a drag is over it.
        .sourceDrop(state: state)
        // The six sheets, presented from one place. Every route that raises one — the File menu,
        // the toolbar, the clickable dropped-rows chip, a dropped workbook, the sidebar's context
        // menu — sets `AppState.modalSheet` and stops; until this modifier existed they all set a
        // value nothing read, so five finished features were unreachable.
        // 🔴 Every `if let` here has an `else`, and that is the belt rather than the fix: `AppState`
        // clears `modalSheet` when its subject table leaves the catalog — see
        // `dismissSheetWithoutASubject`. This is what the user gets if a subject ever goes missing
        // by some route nobody thought of. What used to be here was `if let t = state.active` with
        // no else, which renders a body painting ZERO pixels — a blank window-modal sheet with no
        // button on it. Force-quit.
        .alert(item: Binding(
            get: { state.downloadingExtension ? nil : state.extensionDownloadPrompt },
            set: { _ in }
        )) { prompt in
            Alert(title: Text("Download extension?"), message: Text(prompt.message),
                primaryButton: .default(Text("Download and Open")) {
                    Task { await state.approveExtensionDownload(prompt.id) }
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    state.cancelExtensionDownload(prompt.id)
                })
        }
        .sheet(item: $state.modalSheet, onDismiss: {
            // A missing-reader alert must be presented after the sheet picker has closed.
            guard let action = afterSheetDismissal else { return }
            afterSheetDismissal = nil
            Task { await action() }
        }) { which in
            switch which {
            case .export(let name):
                if let t = state.tables.first(where: { $0.name == name }) {
                    ExportSheet(session: state.session, table: t) { state.banner = $0 }
                } else {
                    SheetSubjectGone()
                }
            case .merge:
                MergeSheet(
                    session: state.session, tables: state.tables.map(\.name),
                    initialLeft: state.activeName
                ) { merged in
                    Task { await state.refresh(); state.activeName = merged.name }
                }
            case .staged:
                StagedDataSheet(session: state.session)
            case .badRows(let name):
                if state.tables.contains(where: { $0.name == name }) {
                    BadRowsSheet(session: state.session, table: name)
                } else {
                    SheetSubjectGone()
                }
            case .workbook(let path):
                SheetPickerSheet(path: path) { picked in
                    afterSheetDismissal = {
                        for name in picked { await state.open(path: path, sheet: name) }
                    }
                }
            case .sheets(let name):
                if let t = state.tables.first(where: { $0.name == name }) {
                    // 🔴 `openSheet(of:sheet:)` and not a second spelling of
                    // `open(path: t.spec.key.path, sheet:)`: that decision — which path a re-open
                    // uses, and that a signed source cannot take it — belongs in one place, and
                    // `SourceTab` asks the same question from the inspector.
                    SheetPickerSheet(
                        title: t.name, sheets: t.spec.sheets, alreadyOpen: t.spec.sheet
                    ) { picked in
                        afterSheetDismissal = {
                            for sheet in picked { await state.openSheet(of: t, sheet: sheet) }
                        }
                    }
                } else {
                    SheetSubjectGone()
                }
            case .openLocation:
                OpenLocationSheet { path in
                    afterSheetDismissal = { await state.open(paths: [path]) }
                }
            case .connections:
                // `state.engine.extensions` and not `session.engineInfo()`: that snapshot was taken
                // once, on the MainActor, while `AppState` was built. See `extensionsAtLaunch`.
                ConnectionsSheet(
                    session: state.session, extensionsAtLaunch: state.engine.extensions)
            }
        }
    }

    /// Open at the leading edge beside SwiftUI's own sidebar toggle, and at the trailing edge the
    /// live row count followed by the three sheets that used to be reachable only from the menu bar.
    ///
    /// Every one of them is `state.can*` or one `present*` call — nothing here decides anything, for
    /// the same reason `AppDelegate`'s actions are one line each: a `View`'s body cannot be tested,
    /// so a rule written in one is a rule nothing checks. The greying reads the SAME properties
    /// `validateMenuItem` does, so the menu item and the button cannot disagree.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onOpen) { Label("Open", systemImage: ToolbarSymbol.open) }
                .help("Open a file or folder")
        }
        // One `ToolbarItem` each rather than a `ToolbarItemGroup`: a group is one indivisible unit
        // to the overflow logic, so all four go behind the » the moment SwiftUI thinks any of them
        // is tight. Separate items are placed and overflowed individually.
        ToolbarItem(placement: .primaryAction) { RowSummaryItem(state: state) }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentMerge() } label: {
                Label("Merge Tables", systemImage: ToolbarSymbol.merge)
            }
            .disabled(!state.canMerge)
            .help("Merge two open tables on a shared key")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentExport() } label: {
                Label("Export", systemImage: ToolbarSymbol.export)
            }
            .disabled(!state.canExport)
            .help("Write the open table out as CSV, Parquet, JSON or XLSX")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentStaged() } label: {
                Label("Staged Data", systemImage: ToolbarSymbol.staged)
            }
            .help("Manage the native copies Sift is holding on disk")
        }
    }
}

/// What a sheet shows when the table it was raised for is no longer open.
///
/// 🔴 It dismisses itself, and it still draws a sentence and a button. That is not belt-and-braces
/// for its own sake: the defect this replaces was a body that painted nothing at all in a
/// window-modal sheet, so if the `.task` below ever fails to run there must still be a way out that
/// does not involve Force Quit. `.cancelAction`, so Escape — the reflex key — is that way out.
struct SheetSubjectGone: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            Text("That table is no longer open.").font(.siftBody)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 400)
        .task { dismiss() }
    }
}

// MARK: - the toolbar's pieces

/// The SF Symbols the toolbar draws.
///
/// 🔴 Named here rather than written inline so `theToolbarsSymbolsAllResolve` can prove each one
/// exists on the floor version. `Label(_, systemImage:)` given a name macOS does not know draws
/// NOTHING and reports nothing — a toolbar button that is present, enabled, hit-testable and
/// invisible, which is a worse bug than the one this toolbar is replacing.
enum ToolbarSymbol {
    static let open = "plus"
    static let merge = "arrow.triangle.merge"
    static let export = "square.and.arrow.down"
    static let staged = "internaldrive"

    static let all = [open, merge, export, staged]
}

/// The live row count — and, when rows were dropped, the way into the bad-rows sheet.
///
/// 🔴 The click target is the whole reason this is not a plain `Text`. "12 dropped" drawn with no
/// way to ask what it means is the defect Task 13 was fixing when it put a click recognizer on an
/// `NSTextField` in the title bar; the phrase carries the product's headline claim and the panel
/// behind it was otherwise unreachable inside `Sift.app`. The underline is the only affordance it
/// gets, and it appears only when there is something to show — an underlined phrase that does
/// nothing would be worse than none.
///
/// Not `.disabled()` on a single button: greying the phrase would dim the row COUNT, which is
/// information rather than a control, on every clean file in the product.
private struct RowSummaryItem: View {
    let state: AppState

    var body: some View {
        if state.canShowBadRows {
            Button { state.presentBadRows() } label: { phrase.underline() }
                .buttonStyle(.plain)
                .help("Show the rows that were dropped")
        } else {
            phrase
        }
    }

    /// `monospacedDigit`, matching the title-bar label this replaces: the count changes every poll
    /// while a background count runs, and proportional digits make the whole phrase twitch.
    private var phrase: some View {
        Text(state.rowSummary)
            .font(.siftLabel.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - detail

/// The grid, plus the two empty states that only make sense once a table is open.
///
/// Which of them is showing is `gridState(columnCount:scrollExtent:rowCountKnown:)`'s decision, not
/// this body's — a body cannot be tested, and that function's edges can.
private struct TableGrid: View {
    let model: TableViewModel
    let onColumnSelected: (String) -> Void
    let onFilterColumn: (String) -> Void
    let onCopyAs: (SnippetDialect) -> Void
    let onError: (String) -> Void

    private var state: GridState {
        gridState(
            columnCount: model.columns.count, scrollExtent: model.scrollExtent,
            rowCountKnown: model.table.displayRows != nil)
    }

    var body: some View {
        Group {
            switch state {
            case .noColumns:
                Text("No columns.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noRows, .rows:
                // 🔴 `.id(model.name)`: `NSViewRepresentable` reuses its coordinator for the life of
                // one view identity, and the coordinator holds the model. Without this, switching
                // tabs leaves the previous table's `GridBridge` driving the new table's grid.
                // 🔴 Both closures wired. The header task built them and could not reach this call
                // site: `onColumnSelected` is a plain header click, which without this does
                // *nothing at all*, and `onError` is a failed shift-click sort — `setSort` runs in a
                // detached `Task`, so there is no caller left to throw to and the banner is the only
                // place that error can go.
                TableGridView(
                    model: model, onColumnSelected: onColumnSelected, onError: onError,
                    onFilterColumn: onFilterColumn, onCopyAs: onCopyAs)
                    .id(model.name)
                    // The "no rows match" state deliberately does NOT cover the header —
                    // so the header, and the filters that emptied the grid, stay
                    // there to be undone. Opaque, so no stale rows show behind it.
                    .overlay(alignment: .top) {
                        if state == .noRows {
                            Text("No rows match the current filters.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                                .padding(.top, gridHeaderInset)
                        }
                    }
            }
        }
        // The §13a busy overlay, on the GRID and nothing else: the actor is blocked, not the app, so
        // the sidebar, the inspector and the menu bar stay live and the scrim covers exactly the
        // thing that has stopped answering.
        .overlay {
            if model.busy.visible { BusyOverlay(message: model.busy.message) }
        }
        // `id:` so switching tabs re-runs this against the newly selected table. The error is
        // surfaced rather than swallowed: `loadFirstPage` is the only thing standing between the
        // user and an empty window, so a `try?` here would be the silent failure this app is
        // supposed to be the opposite of.
        .task(id: model.name) {
            do { try await model.loadFirstPage() } catch { onError(error.localizedDescription) }
        }
    }
}

/// Height of the `NSTableView` header the "no rows" overlay must not cover.
private let gridHeaderInset: CGFloat = 40

/// The no-file-open state: the app icon, a name, one line, and the Open button.
private struct NothingOpenYet: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Nothing Open").font(.siftTitle)
            Text("Drop a file here, or press \u{2318}O.")
                .font(.siftLabel)
                .foregroundStyle(.secondary)
            Button(action: onOpen) { Text("Open\u{2026}") }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            Text("CSV, Parquet, JSON, Excel, Delta, or a folder")
                .font(.siftCaption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
