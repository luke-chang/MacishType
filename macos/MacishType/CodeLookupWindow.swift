import AppKit
import Combine
import SwiftUI

// AppKit shell + SwiftUI detail content, mirroring SettingsWindow: an
// NSSplitViewController with a source-list sidebar of engines and a unified
// toolbar carrying `.sidebarTrackingSeparator` (full-height sidebar chrome).
// The detail pane renders per-character reverse-lookup results.

// MARK: - Window

@MainActor
final class CodeLookupWindow: NSWindow {
    private let sidebar: SidebarListViewController
    private let state = CodeLookupState()
    /// Fingerprint of the sidebar rows. The supported set — and the external
    /// engines' sources — can change while the window is open, so both are
    /// rechecked whenever the window regains key status.
    private var itemsFingerprint: [String]

    private var searchItem: NSSearchToolbarItem?
    private var selected: (item: SettingsSidebarItem, engine: InputEngine)?
    private var query: String
    private var pendingQuery: DispatchWorkItem?
    private var queryGeneration = 0
    private var didFocusSearchOnOpen = false

    init(seedText: String? = nil, initialEngineID: String? = nil) {
        let items = Self.supportedItems()
        itemsFingerprint = Self.sourceFingerprint(for: items)
        sidebar = SidebarListViewController(items: items)
        query = seedText ?? ""

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Fixed width: a wider sidebar squeezes the toolbar's detail section
        // until the search item rests compressed and expands on focus,
        // reflowing the whole toolbar.
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 180
        sidebarItem.canCollapse = true

        // Fill the allotted space: a compact detail state (empty / failure)
        // would otherwise propagate its small intrinsic size back through
        // NSHostingController and shrink the non-resizable window.
        let detailHost = NSHostingController(
            rootView: CodeLookupDetailView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        let detailItem = NSSplitViewItem(viewController: detailHost)

        let split = FixedDividerSplitViewController()
        // Persists sidebar collapse across window recreations; must be set
        // before the split view enters a window.
        split.splitView.autosaveName = "CodeLookup"
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )

        title = String(localized: "Find Input Code")
        contentViewController = split
        // contentViewController collapses the window to the split's
        // fittingSize; restore the intended fixed size.
        setContentSize(NSSize(width: 620, height: 420))
        contentMinSize = NSSize(width: 620, height: 420)
        toolbarStyle = .unified
        if #unavailable(macOS 15) {
            titlebarSeparatorStyle = .none
        }
        isReleasedWhenClosed = false
        animationBehavior = .none

        let bar = NSToolbar(identifier: "codeLookup")
        bar.delegate = self
        bar.displayMode = .iconOnly
        bar.allowsUserCustomization = false
        toolbar = bar

        sidebar.onSelect = { [weak self] item in self?.select(item) }
        sidebar.select(id: initialEngineID)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Refreshes the engine list on every key regain, and focuses the search
    /// field on first open so the user can type immediately (deferred one
    /// tick: toolbar items may materialize after ordering front).
    override func becomeKey() {
        super.becomeKey()
        refreshItems()
        guard !didFocusSearchOnOpen else { return }
        didFocusSearchOnOpen = true
        DispatchQueue.main.async { [weak self] in
            self?.searchItem?.beginSearchInteraction()
        }
    }

    /// supportsReverseLookup implementations only read lightweight state
    /// (bookmark presence, cached or on-disk manifest) — no engine loads.
    private static func supportedItems() -> [SettingsSidebarItem] {
        SettingsSidebarItem.all.dropFirst().filter {
            InputEngine.engine(forSuffix: $0.id)?.supportsReverseLookup == true
        }
    }

    /// Row ids plus the external engines' source paths: a swapped source file
    /// or folder changes the fingerprint even though the row id doesn't.
    private static func sourceFingerprint(for items: [SettingsSidebarItem]) -> [String] {
        items.map { item in
            guard let source = InputEngine.engine(forSuffix: item.id)?.externalSourceURL else {
                return item.id
            }
            return item.id + "|" + InputEngine.canonicalPath(for: source)
        }
    }

    /// Re-derives the sidebar when the supported set or any external source
    /// changed. Lookup state is released first so the re-query starts clean
    /// (fresh index, failure latch cleared) against the new source; the
    /// sidebar update then re-notifies the selection, which re-runs the query.
    private func refreshItems() {
        let fresh = Self.supportedItems()
        let freshFingerprint = Self.sourceFingerprint(for: fresh)
        guard freshFingerprint != itemsFingerprint else { return }
        itemsFingerprint = freshFingerprint
        endLookupSession()
        sidebar.update(items: fresh)
    }

    /// Invalidates the scheduled and in-flight queries (the generation bump
    /// discards any suspended prepare's results) and releases the engine's
    /// lookup state, so whatever session follows starts clean.
    private func endLookupSession() {
        pendingQuery?.cancel()
        queryGeneration += 1
        selected?.engine.endReverseLookup()
        selected = nil
    }

    override func close() {
        endLookupSession()
        super.close()
    }

    /// Called when the window is already open and the menu item fires again.
    /// A nil or all-whitespace seed keeps the current query; a nil engine ID
    /// keeps the current selection.
    func update(seedText: String?, initialEngineID: String?) {
        refreshItems()
        let seed = seedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? seedText : nil
        if let seed {
            query = seed
            searchItem?.searchField.stringValue = seed
        }
        let engineBefore = selected?.engine
        if let id = initialEngineID, sidebar.items.contains(where: { $0.id == id }) {
            sidebar.select(id: id)
        }
        // An actual engine switch already re-queried with the new seed.
        if seed != nil, selected?.engine === engineBefore {
            runQuery()
        }
        // Re-invoking the menu command expresses intent to search — refocus.
        searchItem?.beginSearchInteraction()
    }

    // MARK: Selection & query

    private func select(_ item: SettingsSidebarItem) {
        guard let engine = InputEngine.engine(forSuffix: item.id) else { return }
        guard selected?.engine !== engine else { return }
        selected?.engine.endReverseLookup()
        selected = (item, engine)
        runQuery()
    }

    /// Re-runs the whole query against the selected engine. Prepare is
    /// idempotent and re-awaited every time, so an engine unloaded behind our
    /// back (disabled in System Settings) reloads transparently; a false
    /// return means the engine can't prepare and the detail shows the
    /// failure. The generation counter drops results from superseded runs
    /// and gates the delayed loading indicator, so engines that finish
    /// synchronously never flash it.
    private func runQuery() {
        pendingQuery?.cancel()
        queryGeneration += 1
        guard let selected else { return }
        let generation = queryGeneration
        let engine = selected.engine
        let fallbackTitle = selected.item.title
        Task { [weak self] in
            let loadingFlip = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return   // canceled — the query finished first
                }
                // Re-check cancellation: the sleep can complete right before
                // the cancel, with this body scheduled after the results.
                guard !Task.isCancelled, let self, self.queryGeneration == generation
                else { return }
                self.state.status = .loading
            }
            let ready = await engine.prepareReverseLookup()
            loadingFlip.cancel()
            guard let self, self.queryGeneration == generation else { return }
            // Resolved after prepare: an external table's display name only
            // exists once its table is parsed.
            let name = engine.externalDisplayName ?? fallbackTitle
            if self.state.engineName != name { self.state.engineName = name }
            guard ready else {
                self.state.status = .loadFailed
                self.state.rows = []
                return
            }
            self.state.status = .ready
            var seen = Set<Character>()
            var rows: [CodeLookupState.Row] = []
            for char in self.query where !char.isWhitespace {
                guard seen.insert(char).inserted else { continue }
                rows.append(.init(id: char, codes: engine.reverseLookup(char)))
            }
            self.state.rows = rows
        }
    }

    private func scheduleQuery() {
        pendingQuery?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runQuery() }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

}

// MARK: - Toolbar

extension CodeLookupWindow: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .codeLookupSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .codeLookupSearch else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        item.searchField.delegate = self
        item.searchField.stringValue = query
        item.searchField.placeholderString = String(localized: "Enter characters to look up")
        searchItem = item
        return item
    }
}

extension CodeLookupWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        query = field.stringValue
        scheduleQuery()
    }
}

private extension NSToolbarItem.Identifier {
    static let codeLookupSearch = NSToolbarItem.Identifier("codeLookupSearch")
}

/// Split controller whose divider exposes no resize hot zone: the sidebar
/// width is fixed (min == max), but canCollapse alone would bring the
/// resize cursor back.
private final class FixedDividerSplitViewController: NSSplitViewController {
    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        .zero
    }
}

// MARK: - Detail state (SwiftUI)

@MainActor
final class CodeLookupState: ObservableObject {
    struct Row: Identifiable {
        let id: Character
        let codes: [ReverseCode]

        var character: String { String(id) }
    }

    enum Status {
        case ready
        case loading
        case loadFailed
    }

    @Published var rows: [Row] = []
    @Published var engineName = ""
    @Published var status: Status = .ready
}

// MARK: - Detail content (SwiftUI)

struct CodeLookupDetailView: View {
    @ObservedObject var state: CodeLookupState

    var body: some View {
        if state.status == .loadFailed {
            statusView(
                symbol: "exclamationmark.triangle",
                message: String(localized: "Failed to load this input method"))
        } else if state.status == .loading {
            statusView {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading…")
                }
            }
        } else if state.rows.isEmpty {
            statusView(
                symbol: "character.magnify",
                message: String(localized: "Enter text to look up input codes"))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .center, spacing: 0) {
                                Text(row.character)
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(width: 76, alignment: .center)
                                CodeList(codes: row.codes)
                                    .padding(.trailing, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 40)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[index % 2]))
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Character").frame(width: 76, alignment: .center)
            Text(String(format: String(localized: "%@ Code"), state.engineName))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 30)
    }

    private func statusView(symbol: String, message: String) -> some View {
        statusView { Label(message, systemImage: symbol) }
    }

    private func statusView(@ViewBuilder label: () -> some View) -> some View {
        ContentUnavailableView {
            label()
                .font(.title3)
                // macOS 14 proposes a near-zero width to the title, so CJK
                // wraps one glyph per line; size to content instead.
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Codes with wide gaps, wrapping across lines. A code and its dimmed
/// annotation form one unbreakable unit so wrapping never splits them.
private struct CodeList: View {
    let codes: [ReverseCode]

    var body: some View {
        if codes.isEmpty {
            Text(verbatim: "—").font(.system(size: 14)).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 22, lineSpacing: 6) {
                ForEach(Array(codes.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(entry.code)
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                        if let annotation = entry.annotation {
                            Text(annotation)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

/// Minimal wrapping layout — places subviews left to right, wrapping to a new
/// row when the proposed width is exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
