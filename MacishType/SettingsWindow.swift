import AppKit
import SwiftUI

// AppKit shell + SwiftUI detail content for the Settings window. We use
// NSSplitViewController + NSToolbar (with `sidebarTrackingSeparator`)
// instead of SwiftUI's NavigationSplitView so we get the macOS 26 chrome
// SwiftUI can't fully provide (full-height sidebar, no toggle button,
// large rounded corners). The detail pane is a SwiftUI view hosted via
// NSHostingController; the sidebar swaps the host's rootView when
// selection changes.

// MARK: - Window

@MainActor
final class SettingsWindow: NSWindow {
    private let sidebar = SettingsSidebarViewController()

    init(initialEngineID: String? = nil) {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 215
        // Stops AppKit from auto-inserting the sidebar toggle button.
        sidebarItem.canCollapse = false

        let detailHost = NSHostingController(rootView: SettingsDetailContent(selection: nil))
        let detailItem = NSSplitViewItem(viewController: detailHost)

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )

        contentViewController = split
        // contentViewController collapses the window to the split's fittingSize;
        // restore the intended size and pin a min so the user can't squash it.
        setContentSize(NSSize(width: 620, height: 420))
        contentMinSize = NSSize(width: 620, height: 420)
        titlebarAppearsTransparent = true
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        // Skip the default entrance animation; otherwise the Tahoe rounded
        // corners + sidebar vibrant material visibly settle on first display.
        animationBehavior = .none

        // Attaching a toolbar with `sidebarTrackingSeparator` is what triggers
        // the macOS 26 large rounded corners + sidebar-extends-to-top look.
        let bar = NSToolbar(identifier: "settings")
        bar.delegate = SettingsToolbarDelegate.shared
        bar.displayMode = .iconOnly
        bar.allowsUserCustomization = false
        toolbar = bar

        sidebar.onSelect = { [weak self] item in
            detailHost.rootView = SettingsDetailContent(selection: item?.id)
            self?.title = item?.title ?? ""
        }
        sidebar.select(id: initialEngineID)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    func selectEngine(id: String?) {
        sidebar.select(id: id)
    }
}

// MARK: - Toolbar delegate

@MainActor
private final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = SettingsToolbarDelegate()

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil
    }
}

// MARK: - Sidebar item

struct SettingsSidebarItem: Identifiable {
    let id: String
    let title: String
    let icon: NSImage
}

extension SettingsSidebarItem {
    // Cached for app lifetime. Title is a locale snapshot at first access;
    // runtime locale changes won't refresh. Acceptable for an LSUIElement IME
    // that rarely re-launches. The initializer closure is @MainActor because
    // NSImage(named:) and `.isTemplate` are main-actor isolated under strict
    // concurrency.
    @MainActor
    static let all: [SettingsSidebarItem] = { @MainActor in
        var items: [SettingsSidebarItem] = [
            .init(id: "general",
                  title: String(localized: "General"),
                  icon: symbolImage("gearshape"))
        ]
        guard let comp = Bundle.main.infoDictionary?["ComponentInputModeDict"] as? [String: Any],
              let order = comp["tsVisibleInputModeOrderedArrayKey"] as? [String],
              let list = comp["tsInputModeListKey"] as? [String: [String: Any]]
        else { return items }
        let prefix = (Bundle.main.bundleIdentifier ?? "") + "."
        for fullID in order {
            guard let entry = list[fullID] else { continue }
            let suffix = fullID.hasPrefix(prefix)
                ? String(fullID.dropFirst(prefix.count))
                : fullID
            // Title via InfoPlist.strings (generated from InfoPlist.xcstrings),
            // keyed by the full input source ID. IMK-standard localization
            // channel reused by the system menu.
            let title = Bundle.main.localizedString(
                forKey: fullID,
                value: suffix,
                table: "InfoPlist"
            )
            let iconPath = entry["tsInputModePaletteIconFileKey"] as? String
            let icon = iconPath.flatMap(bundleTemplateImage(_:))
                ?? symbolImage("character.cursor.ibeam")
            items.append(.init(id: suffix, title: title, icon: icon))
        }
        return items
    }()

    private static func symbolImage(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    // Resolves Info.plist icon paths (which may include subdirs) relative
    // to the bundle's Resources/. NSImage(named:) only looks at the flat root.
    private static func bundleTemplateImage(_ relativePath: String) -> NSImage? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(relativePath)
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

// MARK: - Sidebar view controller

@MainActor
final class SettingsSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((SettingsSidebarItem?) -> Void)?

    private let outline = NSOutlineView()
    private let items = SettingsSidebarItem.all

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        outline.headerView = nil
        outline.indentationPerLevel = 0
        outline.style = .sourceList
        outline.rowHeight = 30
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizingMask = [.width, .height]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        scroll.documentView = outline
        view = scroll
    }

    /// Falls back to the first row when `id` is nil or unknown.
    func select(id: String? = nil) {
        let row = id.flatMap { target in items.firstIndex(where: { $0.id == target }) } ?? 0
        if outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            // Outline isn't populated yet (called from init); defer one runloop tick.
            DispatchQueue.main.async { [weak self] in
                self?.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let row = item as? SettingsSidebarItem else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: row.icon)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        let label = NSTextField(labelWithString: row.title)
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        let item = (row >= 0 && row < items.count) ? items[row] : nil
        onSelect?(item)
    }
}

// MARK: - Detail content (SwiftUI)

struct SettingsDetailContent: View {
    let selection: String?

    var body: some View {
        Group {
            if selection == "general" {
                EmptySettingsView()
            } else if let id = selection,
                      let engine = InputEngine.engine(forSuffix: id) {
                engine.settingsView
            } else {
                EmptySettingsView()
            }
        }
        // Force the SwiftUI content to fill its allotted space. Without this,
        // EmptySettingsView's small intrinsic size propagates back through
        // NSHostingController and shrinks the window when the user picks the
        // "General" entry.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Force a full subtree rebuild when selection changes, otherwise
        // SwiftUI diffs between two engines' toggles/pickers and animates
        // the swap (visible reuse + transition between tabs).
        .id(selection)
    }
}

private struct EmptySettingsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No customizable settings.", systemImage: "slider.horizontal.3")
                .font(.title3)  // default .title2 ~22pt; .title3 ~20pt
        }
    }
}
