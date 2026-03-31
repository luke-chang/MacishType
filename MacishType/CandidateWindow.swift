import Cocoa

private extension NSImage {
    static func cornerMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: radius * 2, height: radius * 2), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private class CandidateItemView: NSView {
    private static let indexFontSize: CGFloat = 8
    private static let candidateFontSize: CGFloat = 16

    private static let maxDisplayLength = 5
    private static let indexWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: indexFontSize)
        return (0...9).map { digit in
            ceil(("\(digit)" as NSString).size(withAttributes: [.font: font]).width)
        }.max()!
    }()

    let indexLabel = NSTextField(labelWithString: "")
    let candidateLabel = NSTextField(labelWithString: "")
    var absoluteIndex: Int = 0
    private var widthConstraint: NSLayoutConstraint?

    var isHighlighted: Bool = false {
        didSet { updateAppearance() }
    }

    var highlightColor: NSColor = .selectedContentBackgroundColor {
        didSet {
            guard highlightColor != oldValue else { return }
            updateAppearance()
        }
    }

    var showIndex: Bool = true {
        didSet {
            guard showIndex != oldValue else { return }
            indexLabel.alphaValue = showIndex ? 1 : 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        indexLabel.font = .systemFont(ofSize: Self.indexFontSize)
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.alignment = .center

        candidateLabel.font = .systemFont(ofSize: Self.candidateFontSize)
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indexLabel)
        addSubview(candidateLabel)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: Self.indexWidth),
            candidateLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            candidateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            candidateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize + 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int, candidate: String) {
        indexLabel.stringValue = "\(index)"
        candidateLabel.stringValue = Self.displayText(for: candidate)
    }

    func setFixedWidth(_ width: CGFloat?) {
        if let width {
            if let wc = widthConstraint {
                wc.constant = width
                wc.isActive = true
            } else {
                widthConstraint = widthAnchor.constraint(equalToConstant: width)
                widthConstraint!.isActive = true
            }
        } else {
            widthConstraint?.isActive = false
        }
    }

    static func displayText(for candidate: String) -> String {
        if candidate.count > maxDisplayLength {
            return String(candidate.prefix(maxDisplayLength - 1)) + "…"
        }
        return candidate
    }

    private static let templateView = CandidateItemView()

    static func measureWidth(index: Int, candidate: String) -> CGFloat {
        templateView.configure(index: index, candidate: candidate)
        return ceil(templateView.fittingSize.width)
    }

    override func mouseUp(with event: NSEvent) {
        guard (window as? CandidateWindow)?.didDrag != true else { return }
        (window as? CandidateWindow)?.itemClicked(at: absoluteIndex, doubleClick: event.clickCount >= 2)
    }

    private func updateAppearance() {
        if isHighlighted {
            layer?.backgroundColor = highlightColor.cgColor
            indexLabel.textColor = .white
            candidateLabel.textColor = .white
        } else {
            layer?.backgroundColor = nil
            indexLabel.textColor = .secondaryLabelColor
            candidateLabel.textColor = .labelColor
        }
    }
}

private class RowContainerView: NSView {
    var isRowHighlighted: Bool = false {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = isRowHighlighted
            ? NSColor.alternatingContentBackgroundColors[1].cgColor
            : nil
    }
}

private class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        if (window as? CandidateWindow)?.didDrag != true { onClick?() }
    }
}

// MARK: -

enum NavigationDirection: Hashable {
    case up, down, left, right, home, end
}

protocol CandidateWindowDelegate: AnyObject {
    func candidateSelected(_ candidate: String)
    func candidateSelectionChanged(_ candidate: String)
}

class CandidateWindow: NSPanel {
    static let shared = CandidateWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    private struct GridItem {
        let candidateIndex: Int
        let columnStart: Int
        let columnSpan: Int
    }

    private struct GridRow {
        let items: [GridItem]
    }

    private enum DisplayMode {
        case collapsed
        case expanded
    }

    var indexBase = 1
    var pageSize = 9
    var animationDuration: TimeInterval = 0.15
    private let maxPoolSize = 100
    private let maxDisplayCandidates = 200
    private var candidates: [String] = []
    private var selectedIndex: Int = 0
    private var displayMode: DisplayMode = .collapsed
    private var lastShowNearRect: NSRect = .zero
    private var isAnimating = false
    private var gridRows: [GridRow] = []
    private var baseColumnWidth: CGFloat = 0
    private(set) var didDrag = false

    private var outerStackView: NSStackView!
    private var allItemViews: [CandidateItemView] = []
    private var itemViewPool: [CandidateItemView] = []
    private var rowContainers: [RowContainerView] = []
    private var chevronImageView: ClickableImageView!
    private var chevronSeparator: NSBox!
    private var chevronSeparatorHeight: NSLayoutConstraint?
    private(set) var highlightColor: NSColor = .selectedContentBackgroundColor
    weak var candidateDelegate: CandidateWindowDelegate?
    var bundleIdentifier: String? {
        didSet {
            guard bundleIdentifier != oldValue else { return }
            updateHighlightColor()
        }
    }
    private var accentColorObserver: (any NSObjectProtocol)?

    // MARK: - Init

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        setupUI()
        accentColorObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.accentColorDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateHighlightColor()
        }
    }

    deinit {
        if let observer = accentColorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupUI() {
        outerStackView = NSStackView()
        outerStackView.orientation = .vertical
        outerStackView.spacing = 0
        outerStackView.alignment = .leading
        outerStackView.translatesAutoresizingMaskIntoConstraints = false

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        chevronImageView = ClickableImageView(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
                .withSymbolConfiguration(chevronConfig)!
        )
        chevronImageView.contentTintColor = .secondaryLabelColor
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronImageView.onClick = { [weak self] in
            guard let self, !self.isAnimating, self.displayMode == .collapsed else { return }
            let collapsedCount = self.collapsedVisibleCount
            guard self.displayCount > collapsedCount else { return }
            self.expandWindow(animated: true)
        }
        NSLayoutConstraint.activate([
            chevronImageView.widthAnchor.constraint(equalToConstant: 16),
        ])

        chevronSeparator = NSBox()
        chevronSeparator.boxType = .separator
        chevronSeparator.translatesAutoresizingMaskIntoConstraints = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.maskImage = .cornerMask(radius: 6)

        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true

        visualEffect.addSubview(outerStackView)
        self.contentView = visualEffect

        let bottomConstraint = outerStackView.bottomAnchor.constraint(
            equalTo: visualEffect.bottomAnchor)
        bottomConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            outerStackView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            outerStackView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            outerStackView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            bottomConstraint,
        ])
    }

    private func updateHighlightColor() {
        if ThemeManager.shared.isMulticolor,
           let bundleID = bundleIdentifier,
           let color = ThemeManager.shared.bundleAccentColor(bundleIdentifier: bundleID) {
            highlightColor = color
        } else {
            highlightColor = .selectedContentBackgroundColor
        }
        for item in allItemViews { item.highlightColor = highlightColor }
        for item in itemViewPool { item.highlightColor = highlightColor }
    }

    // MARK: - Public API

    func updateCandidates(_ candidates: [String]) {
        self.candidates = candidates
        self.selectedIndex = 0
        self.displayMode = .collapsed
        self.isAnimating = false
        self.gridRows = []
        rebuildLayout(animated: false)
    }

    func handleNavigation(direction: NavigationDirection, wrapping: Bool = false) {
        guard !candidates.isEmpty, !isAnimating else { return }

        // Down in collapsed mode: expand if there are more candidates
        if displayMode == .collapsed, direction == .down {
            let collapsedCount = collapsedVisibleCount
            if displayCount > collapsedCount {
                expandWindow(animated: true)
            }
            return
        }

        let target = navigationTarget(direction: direction)
            ?? (wrapping ? wrappingTarget(direction: direction) : nil)

        guard let target else {
            if displayMode == .expanded, Self.collapseDirections.contains(direction) {
                collapseWindow(animated: true)
            }
            return
        }

        // Expand if target is beyond collapsed row
        if displayMode == .collapsed {
            let collapsedCount = collapsedVisibleCount
            if target >= collapsedCount {
                selectedIndex = target
                expandWindow(animated: true)
                return
            }
        }

        moveSelection(to: target)
    }

    func commitSelectedCandidate() {
        guard isVisible, selectedIndex >= 0, selectedIndex < displayCount else { return }
        candidateDelegate?.candidateSelected(candidates[selectedIndex])
    }

    func commitCandidateForDigit(_ digit: Int) {
        guard isVisible else { return }
        let itemOffset = digit - indexBase
        guard itemOffset >= 0 else { return }

        guard let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return }
        let row = gridRows[rowIdx]
        guard itemOffset < row.items.count else { return }

        let candidateIndex = row.items[itemOffset].candidateIndex
        guard candidateIndex < candidates.count else { return }
        candidateDelegate?.candidateSelected(candidates[candidateIndex])
    }

    func hide() {
        orderOut(nil)
    }

    func showNear(rect: NSRect) {
        lastShowNearRect = rect
        let topLeftPoint = topLeftPoint(forWindowSize: self.frame.size, near: rect)
        let newOrigin = NSPoint(x: topLeftPoint.x, y: topLeftPoint.y - self.frame.height)
        let dx = newOrigin.x - self.frame.origin.x
        let dy = newOrigin.y - self.frame.origin.y
        let distanceSq = dx * dx + dy * dy

        if isVisible, !isAnimating, distanceSq > 400 {
            isAnimating = true
            let newFrame = NSRect(origin: newOrigin, size: self.frame.size)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        } else if !isAnimating {
            self.setFrameTopLeftPoint(topLeftPoint)
        }
        self.orderFrontRegardless()
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(rect.origin) }
            ?? NSScreen.screens.max(by: { a, b in
                let aRect = a.frame.intersection(rect)
                let bRect = b.frame.intersection(rect)
                let aArea = aRect.isNull ? 0 : aRect.width * aRect.height
                let bArea = bRect.isNull ? 0 : bRect.width * bRect.height
                return aArea < bArea
            })
    }

    private func topLeftPoint(forWindowSize windowSize: NSSize, near rect: NSRect) -> NSPoint {
        let screenRect = screen(containing: rect)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 4.0
        var point = NSPoint(x: rect.minX, y: rect.minY - margin)

        if point.y - windowSize.height < screenRect.minY {
            point.y = rect.maxY + windowSize.height
        }

        if point.x + windowSize.width >= screenRect.maxX {
            point.x = screenRect.maxX - windowSize.width
        }
        if point.x < screenRect.minX {
            point.x = screenRect.minX
        }

        if point.y >= screenRect.maxY {
            point.y = screenRect.maxY - 1.0
        }

        return point
    }

    // MARK: - Dragging

    private var dragOffset: NSPoint = .zero
    private var dragStartScreen: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
        dragStartScreen = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        if !didDrag {
            let dx = screenPoint.x - dragStartScreen.x
            let dy = screenPoint.y - dragStartScreen.y
            guard dx * dx + dy * dy > 9 else { return }
            didDrag = true
        }
        setFrameOrigin(NSPoint(
            x: screenPoint.x - dragOffset.x,
            y: screenPoint.y - dragOffset.y
        ))
    }

    // MARK: - Navigation helpers

    private var displayCount: Int {
        min(candidates.count, maxDisplayCandidates)
    }

    private var collapsedVisibleCount: Int {
        gridRows.first?.items.count ?? 0
    }

    private static let collapseDirections: Set<NavigationDirection> = [.left, .up, .home]

    private func findGridPosition(of candidateIndex: Int) -> (rowIndex: Int, item: GridItem)? {
        for (rowIdx, row) in gridRows.enumerated() {
            if let item = row.items.first(where: { $0.candidateIndex == candidateIndex }) {
                return (rowIdx, item)
            }
        }
        return nil
    }

    private func findOverlappingItem(
        in row: GridRow, columnStart: Int, columnEnd: Int
    ) -> Int? {
        var bestIndex: Int?
        for item in row.items {
            let itemEnd = item.columnStart + item.columnSpan
            if item.columnStart < columnEnd, itemEnd > columnStart {
                if bestIndex == nil || item.candidateIndex < bestIndex! {
                    bestIndex = item.candidateIndex
                }
            }
        }
        return bestIndex
    }

    private func gridNavigateVertical(direction: Int) -> Int? {
        guard let (rowIdx, item) = findGridPosition(of: selectedIndex) else { return nil }
        let targetRowIdx = rowIdx + direction
        guard targetRowIdx >= 0, targetRowIdx < gridRows.count else { return nil }

        let targetRow = gridRows[targetRowIdx]
        return findOverlappingItem(
            in: targetRow,
            columnStart: item.columnStart,
            columnEnd: item.columnStart + item.columnSpan
        ) ?? targetRow.items.last?.candidateIndex
    }

    private func wrappingTarget(direction: NavigationDirection) -> Int? {
        switch direction {
        case .right where selectedIndex >= displayCount - 1:
            return 0
        case .left where selectedIndex <= 0:
            return displayCount - 1
        case .down, .up:
            guard let (rowIdx, item) = findGridPosition(of: selectedIndex) else { return nil }
            let colStart = item.columnStart
            let colEnd = colStart + item.columnSpan
            if direction == .down, rowIdx >= gridRows.count - 1 {
                return findOverlappingItem(in: gridRows[0], columnStart: colStart, columnEnd: colEnd)
            }
            if direction == .up, rowIdx <= 0 {
                let lastRow = gridRows[gridRows.count - 1]
                return findOverlappingItem(in: lastRow, columnStart: colStart, columnEnd: colEnd)
            }
            return nil
        default:
            return nil
        }
    }

    private func navigationTarget(direction: NavigationDirection) -> Int? {
        switch direction {
        case .right:
            return selectedIndex + 1 < displayCount ? selectedIndex + 1 : nil
        case .left:
            return selectedIndex > 0 ? selectedIndex - 1 : nil
        case .down:
            return gridNavigateVertical(direction: 1)
        case .up:
            return gridNavigateVertical(direction: -1)
        case .home:
            return selectedIndex > 0 ? 0 : nil
        case .end:
            let last = displayCount - 1
            return selectedIndex < last ? last : nil
        }
    }

    // MARK: - Expand/Collapse

    private func expandWindow(animated: Bool) {
        displayMode = .expanded
        rebuildLayout(animated: animated, repositionAfter: true)
    }

    private func collapseWindow(animated: Bool) {
        displayMode = .collapsed
        rebuildLayout(animated: false, repositionAfter: true)
    }

    // MARK: - View Pool

    private func dequeueItemView() -> CandidateItemView {
        if let item = itemViewPool.popLast() {
            item.isHighlighted = false
            item.showIndex = true
            item.setFixedWidth(nil)
            return item
        }
        let item = CandidateItemView()
        item.highlightColor = highlightColor
        return item
    }

    private func recycleItemViews() {
        for item in allItemViews {
            item.removeFromSuperview()
        }
        itemViewPool.append(contentsOf: allItemViews)
        allItemViews.removeAll()
        if itemViewPool.count > maxPoolSize {
            itemViewPool.removeFirst(itemViewPool.count - maxPoolSize)
        }
    }

    // MARK: - Layout

    private func rebuildLayout(animated: Bool, repositionAfter: Bool = false) {
        chevronImageView.removeFromSuperview()
        chevronSeparator.removeFromSuperview()
        for view in outerStackView.arrangedSubviews {
            outerStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        recycleItemViews()
        rowContainers.removeAll()
        gridRows.removeAll()

        guard !candidates.isEmpty else { return }

        baseColumnWidth = CandidateItemView.measureWidth(index: indexBase, candidate: "字")

        if displayMode == .collapsed {
            buildCollapsedLayout()
        } else {
            buildExpandedLayout()
        }

        // Clamp selectedIndex for collapsed mode
        if displayMode == .collapsed, let firstRow = gridRows.first {
            let maxValid = firstRow.items.last?.candidateIndex ?? 0
            if selectedIndex > maxValid {
                selectedIndex = maxValid
            }
        }

        updateSelection()

        if animated {
            animateToFittingSize(repositionAfter: repositionAfter)
        } else {
            sizeToFit()
            if repositionAfter, !lastShowNearRect.isEmpty {
                showNear(rect: lastShowNearRect)
            }
        }
    }

    private func buildCollapsedLayout() {
        let maxWidth = baseColumnWidth * CGFloat(pageSize)

        var packedItems: [(candidateIndex: Int, width: CGFloat)] = []
        var usedWidth: CGFloat = 0

        for i in 0..<displayCount {
            if packedItems.count >= pageSize { break }
            let w = CandidateItemView.measureWidth(
                index: packedItems.count + indexBase, candidate: candidates[i]
            )
            if usedWidth + w > maxWidth, !packedItems.isEmpty { break }
            usedWidth += w
            packedItems.append((i, w))
        }

        let allFit = packedItems.count >= displayCount

        let gridItems = packedItems.enumerated().map { pos, item in
            GridItem(candidateIndex: item.candidateIndex, columnStart: pos, columnSpan: 1)
        }
        gridRows = [GridRow(items: gridItems)]

        let firstRow = makeRow(
            gridItems: gridItems, showIndices: true, highlighted: false, fixedWidths: false
        )

        if !allFit {
            let wrapper = NSStackView()
            wrapper.orientation = .horizontal
            wrapper.spacing = 0
            wrapper.alignment = .centerY
            wrapper.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
            wrapper.addArrangedSubview(firstRow)
            wrapper.addArrangedSubview(chevronSeparator)
            wrapper.setCustomSpacing(1, after: chevronSeparator)
            wrapper.addArrangedSubview(chevronImageView)
            chevronSeparatorHeight?.isActive = false
            chevronSeparatorHeight = chevronSeparator.heightAnchor.constraint(
                equalTo: firstRow.heightAnchor, multiplier: 0.5
            )
            chevronSeparatorHeight?.isActive = true
            chevronImageView.isHidden = false
            chevronSeparator.isHidden = false
            outerStackView.addArrangedSubview(wrapper)
        } else {
            outerStackView.addArrangedSubview(firstRow)
        }
    }

    private func buildExpandedLayout() {
        // Compute column spans for all items
        var allSpans: [Int] = []
        for i in 0..<displayCount {
            let w = CandidateItemView.measureWidth(index: indexBase, candidate: candidates[i])
            let span = max(1, min(pageSize, Int(ceil(w / baseColumnWidth))))
            allSpans.append(span)
        }

        // Pack items into grid rows
        var currentRowItems: [GridItem] = []
        var currentColumn = 0

        for i in 0..<displayCount {
            let span = allSpans[i]
            if currentColumn + span > pageSize, !currentRowItems.isEmpty {
                gridRows.append(GridRow(items: currentRowItems))
                currentRowItems = []
                currentColumn = 0
            }
            currentRowItems.append(GridItem(
                candidateIndex: i, columnStart: currentColumn, columnSpan: span
            ))
            currentColumn += span
        }
        if !currentRowItems.isEmpty {
            gridRows.append(GridRow(items: currentRowItems))
        }

        // Build visual rows
        let selectedRowIdx = findGridPosition(of: selectedIndex)?.rowIndex ?? 0

        for (rowIndex, gridRow) in gridRows.enumerated() {
            let isSelectedRow = rowIndex == selectedRowIdx
            let row = makeRow(
                gridItems: gridRow.items,
                showIndices: isSelectedRow,
                highlighted: isSelectedRow,
                fixedWidths: true
            )
            outerStackView.addArrangedSubview(row)
        }

        // Synchronize row widths
        if rowContainers.count > 1 {
            for i in 1..<rowContainers.count {
                rowContainers[i].widthAnchor.constraint(
                    equalTo: rowContainers[0].widthAnchor
                ).isActive = true
            }
        }
    }

    private func makeRow(
        gridItems: [GridItem], showIndices: Bool, highlighted: Bool, fixedWidths: Bool
    ) -> RowContainerView {
        let container = RowContainerView()
        container.isRowHighlighted = highlighted

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        for (position, gridItem) in gridItems.enumerated() {
            let item = dequeueItemView()
            item.absoluteIndex = gridItem.candidateIndex
            item.configure(
                index: position + indexBase, candidate: candidates[gridItem.candidateIndex]
            )
            item.showIndex = showIndices
            if fixedWidths {
                item.setFixedWidth(CGFloat(gridItem.columnSpan) * baseColumnWidth)
            }
            stackView.addArrangedSubview(item)
            allItemViews.append(item)
        }

        // Spacer absorbs remaining width in expanded mode
        if fixedWidths {
            let usedColumns = gridItems.reduce(0) { $0 + $1.columnSpan }
            let remainingColumns = pageSize - usedColumns
            if remainingColumns > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.widthAnchor.constraint(
                    equalToConstant: CGFloat(remainingColumns) * baseColumnWidth
                ).isActive = true
                stackView.addArrangedSubview(spacer)
            }
        }

        rowContainers.append(container)
        return container
    }

    func itemClicked(at index: Int, doubleClick: Bool) {
        guard !isAnimating else { return }
        if doubleClick {
            candidateDelegate?.candidateSelected(candidates[index])
        } else {
            moveSelection(to: index)
        }
    }

    private func moveSelection(to newIndex: Int) {
        let oldRowIdx = findGridPosition(of: selectedIndex)?.rowIndex
        selectedIndex = newIndex
        updateSelection()
        if displayMode == .expanded, oldRowIdx != findGridPosition(of: selectedIndex)?.rowIndex {
            updateRowHighlightsAndIndices()
        }
        candidateDelegate?.candidateSelectionChanged(candidates[newIndex])
    }

    private func updateSelection() {
        for (index, item) in allItemViews.enumerated() {
            item.isHighlighted = index == selectedIndex
        }
    }

    private func updateRowHighlightsAndIndices() {
        guard displayMode == .expanded else { return }
        guard let (selectedRowIdx, _) = findGridPosition(of: selectedIndex) else { return }

        for (rowIndex, row) in gridRows.enumerated() {
            let isSelected = rowIndex == selectedRowIdx
            rowContainers[rowIndex].isRowHighlighted = isSelected
            for gridItem in row.items {
                allItemViews[gridItem.candidateIndex].showIndex = isSelected
            }
        }
    }

    // MARK: - Sizing & Animation

    private func sizeToFit() {
        let fittingSize = outerStackView.fittingSize
        self.setContentSize(fittingSize)
    }

    private func animateToFittingSize(repositionAfter: Bool = false) {
        outerStackView.layoutSubtreeIfNeeded()
        let fittingSize = outerStackView.fittingSize

        let newFrame: NSRect
        if repositionAfter, !lastShowNearRect.isEmpty {
            let topLeft = topLeftPoint(forWindowSize: fittingSize, near: lastShowNearRect)
            newFrame = NSRect(
                x: topLeft.x,
                y: topLeft.y - fittingSize.height,
                width: fittingSize.width,
                height: fittingSize.height
            )
        } else {
            let currentFrame = self.frame
            let screenRect = screen(containing: lastShowNearRect)?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? .zero
            var newOrigin = NSPoint(
                x: currentFrame.origin.x,
                y: currentFrame.maxY - fittingSize.height
            )
            if newOrigin.y < screenRect.minY {
                if !lastShowNearRect.isEmpty {
                    newOrigin.y = lastShowNearRect.maxY
                } else {
                    newOrigin.y = screenRect.minY
                }
            }
            if newOrigin.x + fittingSize.width > screenRect.maxX {
                newOrigin.x = screenRect.maxX - fittingSize.width
            }
            newFrame = NSRect(origin: newOrigin, size: fittingSize)
        }

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
        })
    }
}
