import AppKit

/// Flat source-list sidebar shared by the shell windows (Settings, code
/// lookup): fixed items rendered as icon + title rows, selection reported
/// through `onSelect` for both user clicks and programmatic `select(id:)`.
@MainActor
final class SidebarListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SettingsSidebarItem) -> Void)?

    private let table = NSTableView()
    private(set) var items: [SettingsSidebarItem]

    init(items: [SettingsSidebarItem]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width, .height]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.isEditable = false
        table.addTableColumn(column)

        scroll.documentView = table
        view = scroll
    }

    /// Replaces the rows, keeping the current selection when its id survives
    /// and falling back to the first row when it doesn't. Either way the
    /// resulting selection is notified through `onSelect`.
    func update(items newItems: [SettingsSidebarItem]) {
        let selectedID = (table.selectedRow >= 0 && table.selectedRow < items.count)
            ? items[table.selectedRow].id : nil
        items = newItems
        table.reloadData()
        select(id: selectedID)
    }

    /// Falls back to the first row when `id` is nil or unknown.
    func select(id: String?) {
        guard !items.isEmpty else { return }
        loadViewIfNeeded()
        // The table populates lazily; selecting a row before the first
        // reload is a silent no-op. Force the load so selection lands
        // synchronously.
        if table.numberOfRows == 0 {
            table.reloadData()
        }
        let row = id.flatMap { target in items.firstIndex(where: { $0.id == target }) } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // tableViewSelectionDidChange fires only when the selection actually
        // changes — and allowsEmptySelection = false silently pre-selects
        // row 0 during reload, so selecting row 0 here is a no-change.
        // Notify directly; the windows' handlers are idempotent.
        onSelect?(items[row])
    }

    // MARK: data source

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: delegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: item.icon)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        let label = NSTextField(labelWithString: item.title)
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        onSelect?(items[row])
    }
}
