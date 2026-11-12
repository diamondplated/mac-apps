import SwiftUI
import AppKit
import PhotoViewerCore
import PhotoGeo

enum BrowseMode: String, CaseIterable, Identifiable {
    case grid, map
    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "Map" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "map" }
}

/// Thumbnail sizes offered in View Options. Stored as the point size so the
/// existing `thumbnailSize` preference keeps working; any older value snaps
/// to the nearest preset.
enum ThumbnailSize: Double, CaseIterable, Identifiable {
    case small = 112
    case medium = 160
    case large = 224

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    static func nearest(to value: Double) -> ThumbnailSize {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .medium
    }
}

struct BrowserView: View {
    @Bindable var state: AppState
    /// Owned by the app so File > Export works even while the optional
    /// panel is not in the view hierarchy.
    @Bindable var enhanceState: EnhancementState
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = ThumbnailSize.medium.rawValue
    @State private var locationCache = PhotoLocationCache()
    @State private var showSearch = false
    @State private var searchFocusRequest = 0
    @State private var searchState = DesktopSearchState()
    @FocusState private var viewerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        browserChrome
        // Folder switch hooks.
        .onChange(of: state.folder) { _, newFolder in
            state.searchResultURLs = nil
            searchState.bind(folder: newFolder, readOnly: state.isBrowsingArchive)
            state.photoFilter = .all
            // Forget GPS cache for the previous folder. We'll lazy-rebuild
            // when the user actually opens the map view.
            locationCache.reset()
        }
        .onChange(of: state.folderLoadTick) {
            // A direct/recursive mode switch can reload the same URL, so the
            // folder onChange above will not fire. Retire any ranking captured
            // against the old browser population; the user can rerun it once
            // the new snapshot has settled.
            state.searchResultURLs = nil
            searchState.resetForFolderReload()
        }
        .onChange(of: state.browserFilterResetTick) {
            searchState.resetForExternalSelection()
        }
        .onChange(of: state.searchRequestTick) {
            presentSearch()
        }
        // GPS extraction is the single biggest cost in the load path
        // (header reads on every photo) — only kick it off when the user
        // actually wants the map view, not on every folder open.
        .onChange(of: state.browseMode) { _, newMode in
            browseModeChanged(to: newMode)
        }
        // If the user opens a folder while ALREADY in map mode, fire the
        // first GPS pass once the scan settles. Watch isLoading rather than
        // imageURLs so we don't re-fire per batch.
        .onChange(of: state.isLoading) { _, nowLoading in
            if !nowLoading, state.browseMode == .map {
                rebuildMapLocations(for: state.imageURLs)
            }
            if !nowLoading, showSearch {
                searchState.refreshIndexStatus()
            }
        }
        .onChange(of: state.folderContentsChangeTick) {
            guard showSearch, !state.isLoading else { return }
            searchState.noteFolderContentsChanged()
        }
        // A URL-array change catches watcher additions/removals; the content
        // tick also catches an EXIF/GPS rewrite at the same pathname. Resetting
        // cancels any older metadata pass so removed markers cannot reappear.
        .onChange(of: state.imageURLs) { _, urls in
            guard state.browseMode == .map else { return }
            rebuildMapLocations(for: urls)
        }
        .onChange(of: state.browserContentChangeTick) {
            guard state.browseMode == .map else { return }
            rebuildMapLocations(for: state.imageURLs)
        }
        .onChange(of: searchState.resultFilter) { _, results in
            state.searchResultURLs = results
        }
        .onChange(of: filteredURLs) { _, urls in
            reconcileSelection(with: urls)
        }
        .onChange(of: state.selectedIndex) {
            if !state.isSearchFieldFocused { viewerFocused = true }
            if !state.canEnhanceCurrent { state.showEnhancementPanel = false }
        }
        .onAppear {
            viewerFocused = true
            searchState.bind(folder: state.folder, readOnly: state.isBrowsingArchive)
            thumbnailSize = ThumbnailSize.nearest(to: thumbnailSize).rawValue
        }
        .onDisappear {
            searchState.cancelAllOperations()
            state.searchResultURLs = nil
            state.isSearchFieldFocused = false
            enhanceState.reset()
        }
    }

    private var browserChrome: some View {
        HSplitView {
            // Far-left pane: folder tree (collapsible). Default off — toggled
            // from the toolbar — so the layout stays simple unless the user
            // wants to drill around a parent dir.
            if state.showFolderTree && !state.isBrowsingArchive {
                FolderTreeView(state: state)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }
            sidebar
                .frame(minWidth: 240, idealWidth: 320)
            DetailView(state: state, enhanceState: enhanceState)
                .frame(minWidth: 480)
        }
        .focusable()
        .focused($viewerFocused)
        .focusEffectDisabled()
        .overlay { shortcutOverlay }
        // B is special: hold-to-blink the original. Need both `.down` and
        // `.up` phases so we can release the override when the key lifts.
        .onKeyPress(phases: [.down, .up]) { press in handleBlinkKey(press) }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar { browserToolbar }
    }

    // MARK: - Toolbar

    /// Six controls: folder tree, enclosing folder, grid/map, view options,
    /// search and enhancements, with the position counter between them.
    /// Every shortcut lives on the matching menu item, not here.
    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.showFolderTree.toggle()
            } label: {
                Label("Folder Tree", systemImage: "sidebar.left")
            }
            .help(state.showFolderTree ? "Hide Folder Tree (⌘L)" : "Show Folder Tree (⌘L)")
            .disabled(state.isBrowsingArchive)
        }
        ToolbarItem(placement: .navigation) {
            Button {
                state.goUp()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.up")
            }
            .help("Enclosing Folder (⌘↑)")
            .disabled(!state.canGoUp || state.isLoading)
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $state.browseMode) {
                ForEach(BrowseMode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .help("View as Grid (⌘1) or Map (⌘2)")
        }
        ToolbarItem(placement: .primaryAction) {
            photoCounter
        }
        ToolbarItem(placement: .primaryAction) {
            viewOptionsMenu
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.requestSearch()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search This Folder (⌘F)")
            .disabled(state.folder == nil || state.isLoading || state.isBrowsingArchive)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $state.showEnhancementPanel) {
                Label("Enhancements", systemImage: "wand.and.stars")
            }
            .toggleStyle(.button)
            .help(state.showEnhancementPanel ? "Hide Enhancements (⌘E)" : "Show Enhancements (⌘E)")
            .disabled(!state.canEnhanceCurrent)
        }
    }

    /// Sort, thumbnail size and Include Subfolders in one menu.
    private var viewOptionsMenu: some View {
        Menu {
            Picker("Sort By", selection: $state.photoSort) {
                ForEach(FolderSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .disabled(state.imageURLs.isEmpty || state.isLoading)

            Picker("Thumbnail Size", selection: Binding(
                get: { ThumbnailSize.nearest(to: thumbnailSize) },
                set: { thumbnailSize = $0.rawValue }
            )) {
                ForEach(ThumbnailSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.inline)
            .disabled(state.browseMode != .grid)

            Divider()

            Toggle("Include Subfolders", isOn: Binding(
                get: { state.loadedRecursively },
                set: { _ in state.toggleIncludeSubfolders() }
            ))
            .disabled(!state.canIncludeSubfolders)
        } label: {
            Label("View Options", systemImage: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }

    /// Reads through `state` so Observation tracking sees the same source
    /// of truth the phone companion dispatches into.
    private var vimKeymap: VimKeymap { state.vimKeymap }

    @ViewBuilder
    private var shortcutOverlay: some View {
        if state.showShortcutOverlay {
            KeyboardShortcutOverlay(isPresented: $state.showShortcutOverlay)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if showSearch {
                DesktopSearchBar(
                    state: searchState,
                    currentURL: state.currentURL,
                    visibleURLs: state.imageURLs,
                    currentVisibleURLs: { state.imageURLs },
                    focusRequest: searchFocusRequest,
                    onFocusChange: { state.isSearchFieldFocused = $0 },
                    onClose: closeSearch
                )
                Divider()
            }
            if state.isBrowsingArchive {
                archiveReadOnlyBanner
                Divider()
            }
            ZStack {
                // Don't render the actual grid / map while scanning. SwiftUI
                // would otherwise diff a ForEach over a 1000-item array on
                // every batch update from the streaming scan, which spikes the
                // main thread (rainbow spinner). Show only the loading scene
                // until the scan settles.
                if state.isLoading {
                    loadingOverlay
                } else if state.imageURLs.isEmpty && state.folder != nil {
                    emptyFolderHint
                } else {
                    switch state.browseMode {
                    case .grid:
                        VStack(spacing: 0) {
                            FilterBar(
                                activeFilter: $state.photoFilter,
                                vimKeymap: vimKeymap,
                                imageURLs: state.imageURLs,
                                bursts: state.bursts
                            )
                            Divider()
                            if filteredURLs.isEmpty {
                                emptyFilterHint
                            } else {
                                thumbnailGrid
                            }
                        }
                    case .map:  mapView
                    }
                }
            }
        }
    }

    private var archiveReadOnlyBanner: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            Text("Archive Preview")
                .font(.callout.weight(.medium))
            Text("Read-only")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let source = state.archiveSourceURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([source])
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.horizontal, Theme.Spacing.regular)
        .padding(.vertical, Theme.Spacing.small)
        .background(.background.secondary)
    }

    /// The default load is non-recursive, so opening a folder of folders
    /// lands here. Offer the obvious next step instead of an empty grid.
    private var emptyFolderHint: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Nothing at the top level of this folder.")
        } actions: {
            if state.canIncludeSubfolders && !state.loadedRecursively {
                Button("Include Subfolders") { state.toggleIncludeSubfolders() }
            }
        }
    }

    /// The folder has photos but the active filter or search hides all of
    /// them.
    @ViewBuilder
    private var emptyFilterHint: some View {
        if state.photoFilter == .bursts {
            burstsEmptyHint
        } else {
            plainEmptyFilterHint
        }
    }

    @ViewBuilder
    private var burstsEmptyHint: some View {
        switch state.bursts.phase {
        case .idle, .analyzing:
            ContentUnavailableView {
                Label("Finding Bursts", systemImage: "square.stack")
            } description: {
                Text("Looking for photos taken close together that look alike.")
            }
        case .skipped:
            ContentUnavailableView {
                Label("Too Many Photos", systemImage: "square.stack")
            } description: {
                Text("Burst detection runs on folders of up to \(BurstState.photoLimit.formatted()) photos.")
            } actions: {
                Button("Show All") { state.photoFilter = .all }
            }
        case .ready:
            ContentUnavailableView {
                Label("No Bursts", systemImage: "square.stack")
            } actions: {
                Button("Show All") { state.photoFilter = .all }
            }
        }
    }

    private var plainEmptyFilterHint: some View {
        ContentUnavailableView {
            Label(
                state.searchResultURLs != nil ? "No Matches" : "No \(state.photoFilter.label) Photos",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } actions: {
            if state.photoFilter != .all {
                Button("Show All") { state.photoFilter = .all }
            }
        }
    }

    /// Shown in the sidebar during a folder scan or archive extraction.
    /// Stop keeps whatever the scan has already found.
    @ViewBuilder
    private var loadingOverlay: some View {
        if let phase = state.loadPhase {
            LoadingScene(
                phase: phase,
                lastError: state.lastError,
                onStop: { state.cancelScan() }
            )
            .transition(.opacity)
        }
    }

    /// Toolbar counter: the multi-select count, the filtered count, or the
    /// position. Empty while loading — the loader already shows the count.
    @ViewBuilder
    private var photoCounter: some View {
        if state.isLoading || state.imageURLs.isEmpty {
            EmptyView()
        } else if !state.multiSelection.isEmpty {
            // Accent pill so a bulk selection — which Delete would trash in
            // full — is never easy to miss.
            Text("\(state.multiSelection.count) Selected")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .fixedSize()
        } else {
            let total = state.imageURLs.count
            Group {
                if state.photoFilter == .bursts {
                    Text("\(state.bursts.groups.count) Bursts")
                } else if state.photoFilter != .all || state.searchResultURLs != nil {
                    Text("\(filteredURLs.count) of \(total)")
                } else if let i = state.selectedIndex {
                    Text("\(i + 1) of \(total)")
                } else {
                    Text("\(total) Items")
                }
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    // MARK: - Grid

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: CGFloat(thumbnailSize)), spacing: Theme.Spacing.small)],
                    spacing: Theme.Spacing.small
                ) {
                    // Key cells by URL, not index. Sort/delete reshuffles
                    // positions; URL identity prevents SwiftUI from reusing
                    // a decoded thumbnail for the wrong file.
                    ForEach(filteredURLs, id: \.self) { url in
                        ThumbnailCell(
                            url: url,
                            isSelected: state.currentURL == url,
                            isMultiSelected: state.multiSelection.contains(url),
                            colorLabel: vimKeymap.colorLabel(for: url),
                            isPicked: vimKeymap.isPicked(url),
                            isRejected: vimKeymap.isRejected(url),
                            burst: burstBadge(for: url),
                            size: CGFloat(thumbnailSize),
                            contentRevision: state.browserContentChangeTick,
                            allowsTrash: !state.isBrowsingArchive,
                            onTrash: { state.trashImage(at: url) },
                            onFindSimilar: canFindSimilar(url)
                                ? { findSimilar(to: url) }
                                : nil
                        )
                        .id(url)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(url.lastPathComponent)
                        .accessibilityValue(accessibilityStatus(for: url))
                        .accessibilityAddTraits(
                            state.currentURL == url || state.multiSelection.contains(url)
                                ? .isSelected
                                : []
                        )
                        .accessibilityAction(.default) {
                            state.multiSelection.removeAll()
                            state.select(url: url)
                        }
                        // ⌘-click → toggle this URL in the multi-selection
                        .gesture(
                            TapGesture()
                                .modifiers(.command)
                                .onEnded { _ in toggleMultiSelect(url: url) }
                        )
                        // Shift-click → range select from selectedIndex
                        // anchor through this URL's current index (inclusive)
                        .gesture(
                            TapGesture()
                                .modifiers(.shift)
                                .onEnded { _ in extendMultiSelect(to: url) }
                        )
                        // Plain click → clear multi, set primary
                        .onTapGesture {
                            state.multiSelection.removeAll()
                            state.select(url: url)
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
            .onChange(of: state.selectedIndex) { _, newValue in
                if newValue != nil,
                   let url = state.currentURL,
                   filteredURLs.contains(url) {
                    if reduceMotion {
                        proxy.scrollTo(url, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: Theme.Motion.standard)) {
                            proxy.scrollTo(url, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Multi-selection

    /// Toggle a single thumbnail in the multi-selection (⌘-click handler).
    /// Also makes this URL the primary so subsequent shift-clicks anchor
    /// from here.
    private func toggleMultiSelect(url: URL) {
        guard state.imageURLs.contains(url) else { return }
        if state.multiSelection.contains(url) {
            state.multiSelection.remove(url)
        } else {
            state.multiSelection.insert(url)
        }
        state.select(url: url)
    }

    /// Range-select from the current primary (selectedIndex) through the
    /// clicked URL. Replaces the current multi-selection (Mac shift-click
    /// is "select range from anchor").
    private func extendMultiSelect(to url: URL) {
        let urls = filteredURLs
        guard let idx = urls.firstIndex(of: url) else { return }
        let anchor = state.currentURL.flatMap { urls.firstIndex(of: $0) } ?? idx
        let lo = min(anchor, idx)
        let hi = max(anchor, idx)
        state.multiSelection = Set(urls[lo...hi])
        state.select(url: url)
    }

    /// How a thumbnail shows its place in a burst. Only the Bursts view
    /// decorates photos; elsewhere the grid is unchanged.
    private func burstBadge(for url: URL) -> BurstBadge? {
        guard state.photoFilter == .bursts,
              let group = state.bursts.group(containing: url) else { return nil }
        let isOpen = state.currentURL.map(group.members.contains) ?? false
        if isOpen {
            return .member(suggested: url == group.best, reason: group.reason.label)
        }
        return .stack(others: group.members.count - 1, reason: group.reason.label)
    }

    private var filteredURLs: [URL] {
        state.visibleImageURLs
    }

    private func presentSearch() {
        state.browseMode = .grid
        showSearch = true
        searchFocusRequest &+= 1
        searchState.bind(folder: state.folder, readOnly: state.isBrowsingArchive)
        searchState.refreshIndexStatus()
    }

    private func browseModeChanged(to newMode: BrowseMode) {
        guard newMode == .map else { return }
        // Map currently represents the whole opened folder. Clear grid-only
        // filters so a cluster cannot select an item hidden on return.
        state.photoFilter = .all
        state.searchResultURLs = nil
        searchState.clearResults()
        // Changes that happened while the grid was visible intentionally did
        // not spend work on GPS. Rebuild on every transition so deleted URLs
        // and same-path EXIF rewrites cannot leave stale map markers behind.
        rebuildMapLocations(for: state.imageURLs)
    }

    private func rebuildMapLocations(for urls: [URL]) {
        locationCache.reset()
        Task { await locationCache.locate(urls) }
    }

    private func closeSearch() {
        searchState.resetForClose()
        state.searchResultURLs = nil
        state.isSearchFieldFocused = false
        showSearch = false
        viewerFocused = true
    }

    private func canFindSimilar(_ url: URL) -> Bool {
        guard !state.isBrowsingArchive else { return false }
        switch MediaTyping.detect(url) {
        case .staticImage, .animatedImage: return true
        case .video, .unsupported: return false
        }
    }

    private func findSimilar(to url: URL) {
        presentSearch()
        searchState.findSimilar(to: url, visibleURLs: state.imageURLs)
    }

    private func reconcileSelection(with urls: [URL]) {
        let visible = Set(urls)
        state.multiSelection.formIntersection(visible)
        if let current = state.currentURL, visible.contains(current) { return }
        if let first = urls.first {
            state.select(url: first)
        } else {
            state.selectedIndex = nil
        }
    }

    private func accessibilityStatus(for url: URL) -> String {
        var values: [String] = []
        if state.currentURL == url { values.append("selected") }
        if state.multiSelection.contains(url) { values.append("in multi-selection") }
        if vimKeymap.isPicked(url) { values.append("picked") }
        if vimKeymap.isRejected(url) { values.append("rejected") }
        let label = vimKeymap.colorLabel(for: url)
        if label > 0 { values.append("\(ColorLabel.name(label)) label") }
        return values.isEmpty ? "unreviewed" : values.joined(separator: ", ")
    }

    // MARK: - Map

    private var mapView: some View {
        PhotoMapView(
            locations: locationCache.allLocations,
            onSelectCluster: { urls in
                // Snap selection to the first photo in the cluster and pop
                // back to the grid so the user sees the result laid out.
                if let first = urls.first {
                    state.select(url: first)
                    state.browseMode = .grid
                }
            }
        )
    }

    // MARK: - Blink (hold B to peek at the original)

    /// Hold B to override the compare mode to `.original`. On release, restore
    /// whatever was selected. Returns `.handled` only when the key is B; lets
    /// other keys propagate to `handleKey` (the vim dispatcher).
    @MainActor
    private func handleBlinkKey(_ press: KeyPress) -> KeyPress.Result {
        guard !state.isSearchFieldFocused else { return .ignored }
        guard !state.showShortcutOverlay else { return .ignored }
        guard state.canEnhanceCurrent else { return .ignored }
        guard press.key.character == "b" || press.key.character == "B" else {
            return .ignored
        }
        switch press.phase {
        case .down:    enhanceState.blinking = true
        case .up:      enhanceState.blinking = false
        default: break
        }
        return .handled
    }

    // MARK: - Vim keymap bridge

    /// Translate one SwiftUI keystroke into a `VimAction` and dispatch.
    /// Culling keys (`P`, `X`, digits) and `G` are normally taken by their
    /// Photo and Go menu items before this view sees them; when it does see
    /// them, they go through the same AppState methods the menus call.
    @MainActor
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !state.isSearchFieldFocused else { return .ignored }
        if state.showShortcutOverlay {
            state.showShortcutOverlay = false
            return .handled
        }
        if press.key.character == "?" {
            state.showShortcutOverlay = true
            return .handled
        }
        guard state.ensureActiveFolderContinuity() else { return .handled }

        // AVPlayer owns arrows and Space for transport. Vim j/k remain the
        // dependable way to move between items while a video is selected.
        if let url = state.currentURL,
           MediaTyping.detect(url) == .video {
            switch press.key {
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                return .ignored
            default:
                break
            }
        }

        // When the enhancement panel is open, arrows belong to its sliders
        // and pickers. Vim j/k still navigate photos.
        switch press.key {
        case .leftArrow, .upArrow:
            guard !state.showEnhancementPanel else { return .ignored }
            state.selectPreviousVisible()
            return .handled
        case .rightArrow, .downArrow:
            guard !state.showEnhancementPanel else { return .ignored }
            state.selectNextVisible()
            return .handled
        default: break
        }

        // ⌘, ⌃ and ⌥ chords belong to the menu bar. When their menu item is
        // disabled (⌘1 while loading, say) the press lands here and must not
        // fall through to a bare-key culling action.
        if !press.modifiers.isDisjoint(with: [.command, .control, .option]) {
            return .ignored
        }

        let mods = vimMods(from: press.modifiers)
        let character = press.key.character
        if character == "P" || character == "X" || character.wholeNumberValue != nil {
            state.performCullingKey(character, modifiers: mods)
            return .handled
        }

        let action = vimKeymap.handle(
            keyCharacter: character,
            modifiers: mods,
            currentURL: state.currentURL,
            currentIndex: state.selectedIndex,
            totalCount: state.imageURLs.count
        )

        switch action {
        case .none:
            return .ignored
        default:
            state.dispatch(action)
        }
        return .handled
    }

    private func vimMods(from m: EventModifiers) -> VimModifiers {
        var out = VimModifiers()
        if m.contains(.shift)   { out.insert(.shift) }
        if m.contains(.control) { out.insert(.control) }
        if m.contains(.option)  { out.insert(.option) }
        if m.contains(.command) { out.insert(.command) }
        return out
    }
}

struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    /// In the multi-selection set. Distinct from `isSelected` (which is
    /// the *primary* focus that DetailView shows). A thumbnail can be
    /// both at once — it's the most-recently-clicked AND part of a bulk.
    let isMultiSelected: Bool
    let colorLabel: Int
    let isPicked: Bool
    let isRejected: Bool
    /// Set only in the Bursts view.
    let burst: BurstBadge?
    let size: CGFloat
    /// Restarts the visible cell load after a filesystem batch. Unchanged
    /// files hit ThumbnailLoader's cache; overwritten files were evicted.
    let contentRevision: UInt64
    /// False for temporary archive previews, whose files must not be moved.
    let allowsTrash: Bool
    /// One-click trash. Called from the hover-revealed button and the right-
    /// click context menu — kept as a closure so the cell doesn't need
    /// AppState injected through every preview path.
    let onTrash: () -> Void
    /// Optional because videos and unsupported media cannot be embedded by
    /// the image-only OpenCLIP index.
    let onFindSimilar: (() -> Void)?

    @State private var image: CGImage? = nil
    @State private var hovered: Bool = false
    @State private var didFail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { Theme.shape(Theme.Radius.control) }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else if didFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            // Multi-selected tint overlay. Sits ABOVE the image so it
            // visually unifies a bulk selection at a glance.
            if isMultiSelected {
                Color.accentColor.opacity(0.22)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.5))
        .clipShape(shape)
        .overlay {
            // Border thickness encodes selection state: 3pt for primary,
            // 2pt for "in multi-selection but not primary", none otherwise.
            let lineWidth: CGFloat = isSelected ? 3 : (isMultiSelected ? 2 : 0)
            shape.strokeBorder(
                (isSelected || isMultiSelected) ? Color.accentColor : .clear,
                lineWidth: lineWidth
            )
        }
        .overlay(alignment: .topLeading) {
            if colorLabel > 0 {
                Circle()
                    .fill(ColorLabel.color(colorLabel))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    .padding(Theme.Spacing.tight + 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPicked || isRejected {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isPicked ? Color.green : Color.red)
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    .padding(Theme.Spacing.tight + 1)
            }
        }
        // Hover-revealed trash button. Fades in and out rather than popping.
        // One click moves to Trash (not permanent) so a misclick is
        // recoverable with ⌘Z or from Finder.
        .overlay(alignment: .bottomTrailing) {
            if allowsTrash {
                Button {
                    onTrash()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.red.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.small - 2)
                .help("Move to Trash")
                .accessibilityLabel("Move to Trash")
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .latentAnimation(hovered, reduceMotion: reduceMotion, duration: Theme.Motion.quick)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let burst { BurstBadgeView(badge: burst) }
        }
        // A collapsed burst reads as a stack: two cards peeking out behind.
        .background {
            if case .stack = burst {
                ZStack {
                    shape.fill(.quaternary).offset(x: 6, y: 6)
                    shape.fill(.quaternary.opacity(0.6)).offset(x: 3, y: 3)
                }
                .frame(width: size, height: size)
            }
        }
        .opacity(isRejected ? 0.5 : 1.0)
        .onHover { hovered = $0 }
        // Drag-out delivers the underlying file URL — the same payload
        // Finder gives to Mail, Messages, Photoshop and the rest.
        .draggable(url) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, height: 96)
                }
            }
        }
        .contextMenu {
            // ShareLink wraps NSSharingServicePicker — AirDrop, Mail,
            // Messages, Notes and any share extension the user installed.
            ShareLink(item: url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            if let onFindSimilar {
                Button(action: onFindSimilar) {
                    Label("Find Similar", systemImage: "photo.on.rectangle.angled")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if allowsTrash {
                Divider()
                Button(role: .destructive) {
                    onTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
        .task(id: contentRevision) {
            image = nil
            hovered = false
            didFail = false
            let thumbnail = await ThumbnailLoader.shared.thumbnail(for: url)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                image = thumbnail
            } else {
                withAnimation(.easeOut(duration: Theme.Motion.quick)) { image = thumbnail }
            }
            didFail = thumbnail == nil
        }
    }
}


/// A thumbnail's place in a burst.
enum BurstBadge: Equatable {
    /// A collapsed burst: its suggested frame, with how many others sit under it.
    case stack(others: Int, reason: String)
    /// A frame of the open burst; the suggested one says why.
    case member(suggested: Bool, reason: String)
}

private struct BurstBadgeView: View {
    let badge: BurstBadge

    var body: some View {
        HStack(spacing: 4) {
            switch badge {
            case .stack(let others, let reason):
                Image(systemName: "star.fill")
                Text(reason)
                Text("+\(others)").foregroundStyle(.secondary)
            case .member(let suggested, let reason):
                if suggested {
                    Image(systemName: "star.fill")
                    Text(reason)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .padding(Theme.Spacing.tight + 1)
        .opacity(hidden ? 0 : 1)
        .accessibilityLabel(accessibilityText)
    }

    private var hidden: Bool {
        if case .member(false, _) = badge { return true }
        return false
    }

    private var accessibilityText: String {
        switch badge {
        case .stack(let others, let reason): "Burst, \(reason.lowercased()) frame of \(others + 1)"
        case .member(let suggested, let reason): suggested ? "Suggested, \(reason.lowercased())" : "Burst frame"
        }
    }
}
