import AppKit
import SiftCore
import Testing
@testable import SiftEngine
@testable import SiftUI

// The column-header menu and the Copy As routes: both are the UI for features that already existed
// in the engine (sort and filter state, `Session.snippet`) and had no way in.

@MainActor
private func appKitReady() { _ = NSApplication.shared }

private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
    menu.items.first { $0.title == title }
}

/// 🔴 Every header menu names its column and carries the five commands, and the greying is the
/// model's: Clear Sort is off until there is a sort, the sort in force is checkmarked, and nothing
/// is on in SQL mode, where the header controls are frozen.
@MainActor
@Test(.engineLifetime) func theHeaderMenuHasTheFiveCommandsAndGreysWhatCannotApply() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let bridge = GridBridge(model: model)
    let column = try #require(model.columns.first?.name)

    let menu = bridge.headerMenu(for: column)
    #expect(
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Sort Ascending", "Sort Descending", "Clear Sort", "Filter\u{2026}", "Copy Column Name"])
    #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.representedObject as? String == column })

    let clear = try #require(item(menu, "Clear Sort"))
    #expect(!bridge.validateMenuItem(clear), "there is no sort to clear")

    try await model.setSort([QuerySpec.SortTerm(column: column, direction: .asc)])
    #expect(bridge.validateMenuItem(clear))
    let ascending = try #require(item(menu, "Sort Ascending"))
    let descending = try #require(item(menu, "Sort Descending"))
    #expect(bridge.validateMenuItem(ascending))
    #expect(ascending.state == .on && descending.state == .off, "the sort in force is checkmarked")

    // SQL mode freezes the header: the filters and the sort no longer describe the grid.
    model.typeSQL("SELECT * FROM \"\(model.name)\"")
    try await model.runSQL()
    #expect(model.table.sqlMode)
    #expect(!bridge.validateMenuItem(ascending))
    #expect(!bridge.validateMenuItem(try #require(item(menu, "Filter\u{2026}"))))
}

/// The commands do what they say: Sort Descending sorts the table, Clear Sort empties it again, and
/// Filter… hands the column to whoever is showing its values. Without the sort calls this fails on
/// the first `#expect`, which is the mutation that was run.
@MainActor
@Test(.engineLifetime) func theHeaderMenuCommandsSortClearAndRequestAFilter() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let bridge = GridBridge(model: model)
    let column = try #require(model.columns.first?.name)
    let menu = bridge.headerMenu(for: column)

    var filtered: String?
    bridge.onFilterColumn = { filtered = $0 }
    bridge.filterColumn(try #require(item(menu, "Filter\u{2026}")))
    #expect(filtered == column)

    bridge.sortDescending(try #require(item(menu, "Sort Descending")))
    #expect(await waitFor { model.table.qspec.sort == [QuerySpec.SortTerm(column: column, direction: .desc)] })

    bridge.clearSort(try #require(item(menu, "Clear Sort")))
    #expect(await waitFor { model.table.qspec.sort.isEmpty })
}

/// The gutter has no menu; a data column does. Indices are the table's, so the gutter is 0.
@MainActor
@Test(.engineLifetime) func theGutterHasNoHeaderMenu() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let bridge = GridBridge(model: model)
    #expect(bridge.headerMenu(forColumnIndex: 0) == nil)
    #expect(bridge.headerMenu(forColumnIndex: 1)?.title == model.columns[0].name)
    #expect(bridge.headerMenu(forColumnIndex: model.columns.count + 1) == nil)
}

/// Copy As offers exactly the four dialects the engine knows, on the table's context menu too, and
/// each one produces code from the engine for the current view.
@MainActor
@Test(.engineLifetime) func copyAsOffersEveryDialectTheEngineKnows() async throws {
    appKitReady()
    let (state, model) = try await openedFixture(rows: 12)
    let bridge = GridBridge(model: model)

    let copyAs = try #require(bridge.tableContextMenu().items.first { $0.title == "Copy As" })
    #expect(copyAs.submenu?.items.map(\.title) == ["pandas", "Polars", "DuckDB", "SQL"])

    var asked: [SnippetDialect] = []
    bridge.onCopyAs = { asked.append($0) }
    for entry in copyAs.submenu?.items ?? [] { bridge.copyAs(entry) }
    #expect(asked == [.pandas, .polars, .duckdb, .sql])

    for dialect in SnippetDialect.allCases {
        let code = try await state.session.snippet(model.name, dialect: dialect.rawValue)
        #expect(!code.isEmpty, "\(dialect.title) produced nothing")
    }
}

@MainActor
@Test(.engineLifetime) func openLocationIsASheetThatNeedsNoTable() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    #expect(state.modalSheet == nil)
    state.presentOpenLocation()
    #expect(state.modalSheet == .openLocation)
    #expect(state.modalSheet?.subject == nil, "closing a table must not dismiss it")
}
