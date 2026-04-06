import Cocoa

private extension NSImage {
    static func uniformCornerMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: radius * 2, height: radius * 2), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    static func asymmetricCornerMask(height: CGFloat, leftRadius: CGFloat, rightRadius: CGFloat) -> NSImage {
        let rr = min(rightRadius, height / 2)
        let width = leftRadius + rr + 1
        let image = asymmetricCornerMask(
            size: NSSize(width: width, height: height),
            leftRadius: leftRadius, rightRadius: rightRadius
        )
        image.capInsets = NSEdgeInsets(top: rr, left: leftRadius, bottom: rr, right: rr)
        image.resizingMode = .stretch
        return image
    }

    static func asymmetricCornerMask(size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let lr = min(leftRadius, rect.height / 2)
            let rr = min(rightRadius, rect.height / 2)
            path.move(to: NSPoint(x: lr, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - rr, y: rect.maxY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - rr, y: rect.maxY - rr),
                           radius: rr, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: rect.maxX, y: rr))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - rr, y: rr),
                           radius: rr, startAngle: 0, endAngle: -90, clockwise: true)
            path.line(to: NSPoint(x: lr, y: 0))
            path.appendArc(withCenter: NSPoint(x: lr, y: lr),
                           radius: lr, startAngle: -90, endAngle: -180, clockwise: true)
            path.line(to: NSPoint(x: 0, y: rect.maxY - lr))
            path.appendArc(withCenter: NSPoint(x: lr, y: rect.maxY - lr),
                           radius: lr, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()
            path.fill()
            return true
        }
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: -

enum NavigationDirection: Hashable {
    case up, down, left, right, home, end, pageUp, pageDown
    case tabForward, tabBackward
}

struct CandidateWindowConfiguration {
    var indexBase = 1
    var pageSize = 9
    var widerExpandedColumns = true
    var moveOnExpand = false
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
        let measuredWidth: CGFloat
    }

    private struct GridRow {
        let items: [GridItem]
    }

    private enum DisplayMode {
        case collapsed
        case expanded
    }

    // MARK: - Public Properties

    private(set) var indexBase = 1
    private(set) var pageSize = 9
    private(set) var widerExpandedColumns = true
    private(set) var moveOnExpand = false
    var animationDuration: TimeInterval = 0.183
    private(set) var highlightColor: NSColor = .selectedContentBackgroundColor
    private(set) var didDrag = false
    weak var candidateDelegate: CandidateWindowDelegate?
    var bundleIdentifier: String? {
        didSet {
            guard bundleIdentifier != oldValue else { return }
            updateHighlightColor()
        }
    }

    // MARK: - Private State

    private static let separatorHeight: CGFloat = 1
    private let maxExpandedVisibleRows = 5
    private let maxDisplayCandidates = 200
    private var candidates: [String] = []
    private var selectedIndex: Int = 0
    private var displayMode: DisplayMode = .collapsed
    private var lastShowNearRect: NSRect = .zero
    private var isAnimating = false
    private var gridRows: [GridRow] = []
    private var expandedGridRows: [GridRow] = []
    private var baseColumnWidth: CGFloat = 0
    private var expandedColumnWidth: CGFloat = 0
    private var expandedPageSize: Int = 0
    private var itemHeight: CGFloat = 0
    private var expandedRowsBuilt = false

    // MARK: - View Hierarchy

    // All items in row 0 (collapsed visible + overflow)
    private var row0ItemViews: [CandidateItemView] = []
    // Items in rows 1+ (created on first expand)
    private var expandedItemViews: [CandidateItemView] = []
    private var visualEffectView: NSVisualEffectView!
    private var scrollView: NSScrollView!
    private var candidateContainer: FlippedView!
    private var chevronView: ChevronView!
    private var rowHighlightView: HighlightBackgroundView!
    private var separatorViews: [SeparatorLineView] = []
    private var accentColorObserver: (any NSObjectProtocol)?
    private var scrollerStyleObserver: (any NSObjectProtocol)?
    private var cornerDisplayLink: (any NSObjectProtocol)?
    private var cornerAnimationStart: CFTimeInterval = 0
    private var cornerRadiusFrom: CGFloat = 0
    private var cornerRadiusTo: CGFloat = 0

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
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollerStyleChange()
        }
    }

    deinit {
        if let observer = accentColorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = scrollerStyleObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static let defaultCornerRadius: CGFloat = 6
    private static let uniformMask = NSImage.uniformCornerMask(radius: defaultCornerRadius)
    private var pillMask: NSImage?
    private var pillMaskHeight: CGFloat = 0

    private func pillCornerMask(height: CGFloat) -> NSImage {
        if height == pillMaskHeight, let pillMask { return pillMask }
        let lr = Self.defaultCornerRadius
        let rr = height / 2
        let mask = NSImage.asymmetricCornerMask(height: height, leftRadius: lr, rightRadius: rr)
        pillMask = mask
        pillMaskHeight = height
        return mask
    }

    private func updateMaskImage() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        let showChevron = displayMode == .collapsed && displayCount > collapsedVisibleCount
        if showChevron {
            visualEffectView.maskImage = pillCornerMask(height: size.height)
        } else {
            visualEffectView.maskImage = Self.uniformMask
        }
    }

    private func animateCornerRadius(from: CGFloat, to: CGFloat) {
        stopCornerAnimation()
        cornerRadiusFrom = from
        cornerRadiusTo = to
        cornerAnimationStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            self?.cornerAnimationTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        cornerDisplayLink = timer
    }

    private func stopCornerAnimation() {
        (cornerDisplayLink as? Timer)?.invalidate()
        cornerDisplayLink = nil
    }

    private func cornerAnimationTick() {
        let elapsed = CACurrentMediaTime() - cornerAnimationStart
        let progress = min(elapsed / animationDuration, 1.0)
        // Ease in-out approximation matching CAMediaTimingFunction(.easeInEaseOut)
        let t = progress < 0.5
            ? 2 * progress * progress
            : -1 + (4 - 2 * progress) * progress
        let radius = cornerRadiusFrom + (cornerRadiusTo - cornerRadiusFrom) * t
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        visualEffectView.maskImage = .asymmetricCornerMask(
            size: size, leftRadius: Self.defaultCornerRadius, rightRadius: radius
        )
        if progress >= 1.0 {
            stopCornerAnimation()
        }
    }

    private func setupUI() {
        visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.masksToBounds = true
        self.contentView = visualEffectView

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        visualEffectView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        candidateContainer = FlippedView()
        scrollView.documentView = candidateContainer

        rowHighlightView = HighlightBackgroundView()
        candidateContainer.addSubview(rowHighlightView)

        chevronView = ChevronView()
        chevronView.onClick = { [weak self] in
            guard let self, !self.isAnimating, self.displayMode == .collapsed else { return }
            let collapsedCount = self.collapsedVisibleCount
            guard self.displayCount > collapsedCount else { return }
            self.expandWindow(animated: true)
        }
        candidateContainer.addSubview(chevronView)
    }

    private func updateHighlightColor() {
        if ThemeManager.shared.isMulticolor,
           let bundleID = bundleIdentifier,
           let color = ThemeManager.shared.bundleAccentColor(bundleIdentifier: bundleID) {
            highlightColor = color
        } else {
            highlightColor = .selectedContentBackgroundColor
        }
        for item in row0ItemViews { item.highlightColor = highlightColor }
        for item in expandedItemViews { item.highlightColor = highlightColor }
    }

    // MARK: - Public API

    func apply(_ configuration: CandidateWindowConfiguration) {
        indexBase = configuration.indexBase
        pageSize = configuration.pageSize
        widerExpandedColumns = configuration.widerExpandedColumns
        moveOnExpand = configuration.moveOnExpand
        if isVisible, !candidates.isEmpty {
            resetState()
            rebuildLayout(animated: false, repositionAfter: true)
        }
    }

    func updateCandidates(_ candidates: [String]) {
        self.candidates = candidates
        self.selectedIndex = 0
        resetState()
        self.gridRows = []
        rebuildLayout(animated: false)
    }

    private func resetState() {
        displayMode = .collapsed
        isAnimating = false
        expandedGridRows = []
        expandedRowsBuilt = false
        stopCornerAnimation()
    }

    func handleNavigation(direction: NavigationDirection, wrapping: Bool = false) {
        guard !candidates.isEmpty, !isAnimating else { return }

        let shouldMoveOnExpand = direction == .right || direction == .tabForward
            || (moveOnExpand && (direction == .down || direction == .pageDown))

        if displayMode == .collapsed, direction == .down || direction == .pageDown || direction == .tabForward {
            let collapsedCount = collapsedVisibleCount
            if displayCount > collapsedCount {
                if !expandedRowsBuilt {
                    expandedGridRows = computeExpandedGrid()
                }
                if shouldMoveOnExpand {
                    let jumpRows = direction == .pageDown ? maxExpandedVisibleRows - 1 : 1
                    let targetRowIdx = min(jumpRows, expandedGridRows.count - 1)
                    let targetRow = expandedGridRows[targetRowIdx]
                    let savedGridRows = gridRows
                    gridRows = expandedGridRows
                    if let (rowIdx, item) = findGridPosition(of: selectedIndex) {
                        if rowIdx == 0 {
                            if let target = findOverlappingItem(in: targetRow, columnStart: item.columnStart, columnEnd: item.columnStart + item.columnSpan) {
                                selectedIndex = target
                            } else {
                                selectedIndex = targetRow.items.last!.candidateIndex
                            }
                        } else {
                            selectedIndex = targetRow.items.last!.candidateIndex
                        }
                    }
                    gridRows = savedGridRows
                }
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

        if displayMode == .collapsed {
            let collapsedCount = collapsedVisibleCount
            if target >= collapsedCount {
                if shouldMoveOnExpand {
                    selectedIndex = target
                }
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
            point.y = rect.maxY + windowSize.height + margin
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

    // MARK: - Navigation Helpers

    private var displayCount: Int {
        min(candidates.count, maxDisplayCandidates)
    }

    private var collapsedVisibleCount: Int {
        gridRows.first?.items.count ?? 0
    }

    private static let collapseDirections: Set<NavigationDirection> = [.left, .up, .pageUp]

    private func findGridPosition(of candidateIndex: Int) -> (rowIndex: Int, item: GridItem)? {
        findGridPosition(of: candidateIndex, in: gridRows)
    }

    private func findGridPosition(of candidateIndex: Int, in rows: [GridRow]) -> (rowIndex: Int, item: GridItem)? {
        for (rowIdx, row) in rows.enumerated() {
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

    private func gridNavigateVertical(direction: Int, rowCount: Int = 1) -> Int? {
        guard let (rowIdx, item) = findGridPosition(of: selectedIndex) else { return nil }
        let targetRowIdx = rowIdx + direction * rowCount
        let clampedRowIdx = max(0, min(targetRowIdx, gridRows.count - 1))
        guard clampedRowIdx != rowIdx else { return nil }

        let targetRow = gridRows[clampedRowIdx]
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
        case .tabForward where selectedIndex >= displayCount - 1:
            return 0
        case .left where selectedIndex <= 0:
            return displayCount - 1
        case .tabBackward where selectedIndex <= 0:
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
            guard let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return nil }
            let first = gridRows[rowIdx].items.first!.candidateIndex
            return selectedIndex != first ? first : nil
        case .end:
            guard let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return nil }
            let last = gridRows[rowIdx].items.last!.candidateIndex
            return selectedIndex != last ? last : nil
        case .pageUp:
            return gridNavigateVertical(direction: -1, rowCount: maxExpandedVisibleRows - 1)
        case .pageDown:
            return gridNavigateVertical(direction: 1, rowCount: maxExpandedVisibleRows - 1)
        case .tabForward:
            return selectedIndex + 1 < displayCount ? selectedIndex + 1 : nil
        case .tabBackward:
            return selectedIndex > 0 ? selectedIndex - 1 : nil
        }
    }

    // MARK: - Grid Computation

    private func computeExpandedGrid() -> [GridRow] {
        var rows: [GridRow] = []
        var currentRowItems: [GridItem] = []
        var currentColumn = 0

        for i in 0..<displayCount {
            let w = CandidateItemView.measureWidth(index: indexBase, candidate: candidates[i])
            let span = max(1, min(expandedPageSize, Int(ceil(w / expandedColumnWidth))))
            if currentColumn + span > expandedPageSize, !currentRowItems.isEmpty {
                rows.append(GridRow(items: currentRowItems))
                currentRowItems = []
                currentColumn = 0
            }
            currentRowItems.append(GridItem(
                candidateIndex: i, columnStart: currentColumn, columnSpan: span, measuredWidth: w
            ))
            currentColumn += span
        }
        if !currentRowItems.isEmpty {
            rows.append(GridRow(items: currentRowItems))
        }
        return rows
    }

    private func computeCollapsedGrid() -> [GridRow] {
        let maxWidth = baseColumnWidth * CGFloat(pageSize)
        var packedItems: [(candidateIndex: Int, width: CGFloat)] = []
        var usedWidth: CGFloat = 0

        for i in 0..<displayCount {
            if packedItems.count >= pageSize { break }
            let w = min(
                CandidateItemView.measureWidth(index: packedItems.count + indexBase, candidate: candidates[i]),
                maxWidth
            )
            if usedWidth + w > maxWidth, !packedItems.isEmpty { break }
            usedWidth += w
            packedItems.append((i, w))
        }

        let gridItems = packedItems.enumerated().map { pos, item in
            GridItem(candidateIndex: item.candidateIndex, columnStart: pos, columnSpan: 1, measuredWidth: item.width)
        }
        return [GridRow(items: gridItems)]
    }

    // MARK: - Layout

    // Container is flipped, so row 0 is at y=0 (top).
    private func yForRow(_ rowIndex: Int) -> CGFloat {
        CGFloat(rowIndex) * (itemHeight + Self.separatorHeight)
    }

    @discardableResult
    private func layoutItems() -> NSSize {
        let rowCount = displayMode == .expanded ? gridRows.count : 1
        let contentHeight = CGFloat(rowCount) * itemHeight
            + CGFloat(max(rowCount - 1, 0)) * Self.separatorHeight

        let expandedRow0Indices: Set<Int>
        if displayMode == .expanded {
            expandedRow0Indices = Set(gridRows[0].items.map(\.candidateIndex))
        } else {
            expandedRow0Indices = []
        }

        let gridWidth = expandedColumnWidth * CGFloat(expandedPageSize)
        let row0Y = yForRow(0)
        var row0Width: CGFloat = 0

        // Layout row 0 items
        for item in row0ItemViews {
            if displayMode == .expanded, !expandedRow0Indices.contains(item.absoluteIndex) {
                item.isHidden = true
                continue
            }
            item.isHidden = false
            item.alphaValue = 1

            let w: CGFloat
            if let gridItem = gridRows[0].items.first(where: { $0.candidateIndex == item.absoluteIndex }) {
                w = displayMode == .expanded
                    ? CGFloat(gridItem.columnSpan) * expandedColumnWidth
                    : max(baseColumnWidth, gridItem.measuredWidth)
            } else {
                w = baseColumnWidth
            }
            item.frame = NSRect(x: row0Width, y: row0Y, width: w, height: itemHeight)
            row0Width += w
        }

        // Chevron
        let hasOverflow = displayCount > collapsedVisibleCount
        let chevronWidth = chevronView.intrinsicContentSize.width
        if displayMode == .collapsed, hasOverflow {
            chevronView.isHidden = false
            chevronView.alphaValue = 1
            chevronView.frame = NSRect(x: row0Width, y: row0Y, width: chevronWidth, height: itemHeight)
        } else {
            chevronView.isHidden = true
        }

        let contentWidth: CGFloat
        if displayMode == .expanded {
            contentWidth = gridWidth
        } else {
            contentWidth = row0Width + (hasOverflow ? chevronWidth : 0)
        }

        // Layout rows 1+ items
        if displayMode == .expanded {
            for item in expandedItemViews {
                item.isHidden = false
                guard let (rowIdx, gridItem) = findGridPosition(of: item.absoluteIndex, in: expandedGridRows) else {
                    item.isHidden = true
                    continue
                }
                let x = CGFloat(gridItem.columnStart) * expandedColumnWidth
                let y = yForRow(rowIdx)
                let w = CGFloat(gridItem.columnSpan) * expandedColumnWidth
                item.frame = NSRect(x: x, y: y, width: w, height: itemHeight)
            }
        } else {
            for item in expandedItemViews {
                item.isHidden = true
            }
        }

        let maxVisibleHeight = (CGFloat(maxExpandedVisibleRows) + 0.5) * itemHeight
            + CGFloat(maxExpandedVisibleRows - 1) * Self.separatorHeight
        let needsScrolling = displayMode == .expanded && contentHeight > maxVisibleHeight
        let windowHeight = needsScrolling ? maxVisibleHeight : contentHeight

        var windowWidth = contentWidth
        if needsScrolling {
            windowWidth += NSScroller.scrollerWidth(
                for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        }

        if displayMode == .expanded, let (rowIdx, _) = findGridPosition(of: selectedIndex) {
            let y = yForRow(rowIdx)
            rowHighlightView.frame = NSRect(x: 0, y: y, width: windowWidth, height: itemHeight)
        }

        // Row separators
        let separatorCount = max(rowCount - 1, 0)
        while separatorViews.count < separatorCount {
            let sep = SeparatorLineView()
            candidateContainer.addSubview(sep, positioned: .above, relativeTo: rowHighlightView)
            separatorViews.append(sep)
        }
        for i in 0..<separatorCount {
            separatorViews[i].frame = NSRect(
                x: 0, y: yForRow(i) + itemHeight,
                width: windowWidth, height: Self.separatorHeight)
            separatorViews[i].needsDisplay = true
        }

        candidateContainer.frame.size = NSSize(width: contentWidth, height: contentHeight)
        return NSSize(width: windowWidth, height: windowHeight)
    }

    /// Indices of row 0 candidates that overflow when expanded (not in expanded row 0).
    private var overflowIndices: Set<Int> {
        let expandedRow0 = Set(expandedGridRows[0].items.map(\.candidateIndex))
        let allRow0 = Set(row0ItemViews.map(\.absoluteIndex))
        return allRow0.subtracting(expandedRow0)
    }

    /// Indices in rows 1+ that duplicate overflow items from row 0.
    private var overflowDuplicateIndices: Set<Int> {
        let overflow = overflowIndices
        return Set(expandedItemViews.filter { overflow.contains($0.absoluteIndex) }.map(\.absoluteIndex))
    }

    private func rebuildLayout(animated: Bool, repositionAfter: Bool = false) {
        removeAllItemViews()
        separatorViews.forEach { $0.removeFromSuperview() }
        separatorViews.removeAll()
        rowHighlightView.alphaValue = 0

        guard !candidates.isEmpty else {
            setContentSize(NSSize(width: 0, height: 0))
            return
        }

        baseColumnWidth = CandidateItemView.measureWidth(index: indexBase, candidate: "字")
        if widerExpandedColumns {
            expandedPageSize = pageSize - pageSize / 3
            expandedColumnWidth = baseColumnWidth * CGFloat(pageSize) / CGFloat(expandedPageSize)
        } else {
            expandedPageSize = pageSize
            expandedColumnWidth = baseColumnWidth
        }
        itemHeight = CandidateItemView(frame: .zero).fittingSize.height
        gridRows = computeCollapsedGrid()

        // Create row 0 items
        for (pos, gridItem) in gridRows[0].items.enumerated() {
            let item = createItemView()
            item.absoluteIndex = gridItem.candidateIndex
            item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
            candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
            row0ItemViews.append(item)
        }

        updateSelection()

        let contentSize = layoutItems()
        setContentSize(contentSize)
        updateMaskImage()

        if repositionAfter, !lastShowNearRect.isEmpty {
            showNear(rect: lastShowNearRect)
        }
    }

    // MARK: - Expand/Collapse

    private func expandWindow(animated: Bool) {
        // Capture state before changes
        let oldRow0Frames = row0ItemViews.map { ($0, $0.frame) }
        let oldChevronFrame = chevronView.frame
        let oldChevronHidden = chevronView.isHidden
        let collapsedWidth = frame.size.width

        displayMode = .expanded

        if !expandedRowsBuilt {
            expandedGridRows = computeExpandedGrid()
        }
        gridRows = expandedGridRows

        // Reconfigure row 0 staying items with expanded indices
        let expandedRow0 = gridRows[0]
        for (pos, gridItem) in expandedRow0.items.enumerated() {
            if let item = row0ItemViews.first(where: { $0.absoluteIndex == gridItem.candidateIndex }) {
                item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
            }
        }

        // Create rows 1+ items on first expand
        if !expandedRowsBuilt {
            for rowIndex in 1..<gridRows.count {
                let gridRow = gridRows[rowIndex]
                for (pos, gridItem) in gridRow.items.enumerated() {
                    let item = createItemView()
                    item.absoluteIndex = gridItem.candidateIndex
                    item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
                    candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
                    expandedItemViews.append(item)
                }
            }
            expandedRowsBuilt = true
        }

        // Compute final layout (sets frames and isHidden states)
        let contentSize = layoutItems()

        // Reset scroll to top
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Update after layout so hidden state is correct
        updateRowHighlightsAndIndices()
        updateSelection()
        let targetWindowFrame = windowFrame(for: contentSize, reposition: true)

        if !animated {
            rowHighlightView.alphaValue = 1
            setContentSize(contentSize)
            updateMaskImage()
            scrollSelectedRowIntoView()
            if !lastShowNearRect.isEmpty { showNear(rect: lastShowNearRect) }
            return
        }

        // --- Animated expand ---
        let overflow = overflowIndices
        let overflowDups = overflowDuplicateIndices

        // Save target frames, then set initial animation state
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }
        var targetExpandedFrames: [Int: NSRect] = [:]
        for item in expandedItemViews {
            targetExpandedFrames[item.absoluteIndex] = item.frame
        }

        // Row 0 staying items: restore to old frames
        for (item, oldFrame) in oldRow0Frames {
            if !overflow.contains(item.absoluteIndex) {
                item.frame = oldFrame
            }
        }

        // Row 0 overflow items: unhide at old frame, will fade out + slide right
        for (item, oldFrame) in oldRow0Frames {
            if overflow.contains(item.absoluteIndex) {
                item.isHidden = false
                item.alphaValue = 1
                item.frame = oldFrame
            }
        }

        // Rows 1+ overflow duplicates: start off-screen left, alpha 0
        for item in expandedItemViews {
            if overflowDups.contains(item.absoluteIndex) {
                let target = targetExpandedFrames[item.absoluteIndex]!
                item.frame = NSRect(x: -target.width, y: target.minY, width: target.width, height: target.height)
                item.alphaValue = 0
            } else {
                item.alphaValue = 1
            }
        }

        // Chevron: restore to old position
        if !oldChevronHidden {
            chevronView.isHidden = false
            chevronView.alphaValue = 1
            chevronView.frame = oldChevronFrame
        }

        // Row highlight starts invisible
        rowHighlightView.alphaValue = 0

        scrollView.hasVerticalScroller = false

        // Animate corner radius from pill to uniform
        animateCornerRadius(from: frame.size.height / 2, to: Self.defaultCornerRadius)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // Window resize
            self.animator().setFrame(targetWindowFrame, display: true)

            // Row 0 staying items: animate to target
            for item in self.row0ItemViews where !overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {

                    item.animator().frame = target
                }
            }

            // Row 0 overflow items: fade out + slide right
            for item in self.row0ItemViews where overflow.contains(item.absoluteIndex) {

                let slideTarget = collapsedWidth - item.frame.origin.x
                item.animator().alphaValue = 0
                var f = item.frame
                f.origin.x += slideTarget
                item.animator().frame = f
            }

            // Rows 1+ overflow duplicates: slide in from left + fade in
            for item in self.expandedItemViews where overflowDups.contains(item.absoluteIndex) {
                if let target = targetExpandedFrames[item.absoluteIndex] {

                    item.animator().frame = target
                    item.animator().alphaValue = 1
                }
            }

            // Chevron: fade out, track right edge
            if !oldChevronHidden {
                self.chevronView.animator().alphaValue = 0
                let chevronTargetX = max(
                    targetRow0Frames.values.map(\.maxX).max() ?? 0,
                    contentSize.width - self.chevronView.frame.width
                )
                var cf = self.chevronView.frame
                cf.origin.x = chevronTargetX
                self.chevronView.animator().frame = cf
            }

            // Row highlight fade in
            self.rowHighlightView.animator().alphaValue = 1

        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hide overflow items
            for item in self.row0ItemViews where overflow.contains(item.absoluteIndex) {
                item.isHidden = true
            }
            self.chevronView.isHidden = true
            self.isAnimating = false
            let hasOverflow = self.scrollView.documentView!.frame.height
                > self.scrollView.contentView.bounds.height
            self.scrollView.hasVerticalScroller = hasOverflow
            if hasOverflow, NSScroller.preferredScrollerStyle != .legacy {
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                self.scrollView.flashScrollers()
            }
            self.scrollSelectedRowIntoView()
        })
    }

    private func collapseWindow(animated: Bool) {
        // Capture state before changes
        let oldExpandedFrames = expandedItemViews.map { ($0, $0.frame) }
        let overflow = overflowIndices
        let overflowDups = overflowDuplicateIndices

        displayMode = .collapsed
        gridRows = computeCollapsedGrid()

        // Reconfigure row 0 items with collapsed indices
        for (pos, gridItem) in gridRows[0].items.enumerated() {
            if let item = row0ItemViews.first(where: { $0.absoluteIndex == gridItem.candidateIndex }) {
                item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
            }
        }

        // Reset scroll to top
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Clamp selectedIndex
        let maxValid = gridRows[0].items.last?.candidateIndex ?? 0
        if selectedIndex > maxValid {
            selectedIndex = maxValid
        }
        updateSelection()

        // Compute final layout
        let contentSize = layoutItems()
        let targetWindowFrame = windowFrame(for: contentSize, reposition: true)

        if !animated {
            rowHighlightView.alphaValue = 0
            for item in row0ItemViews { item.alphaValue = 1 }
            setContentSize(contentSize)
            updateMaskImage()
            if !lastShowNearRect.isEmpty { showNear(rect: lastShowNearRect) }
            return
        }

        // --- Animated collapse ---

        // Save target frames for row 0
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews where !item.isHidden {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }

        // Row 0 overflow items: start from right side, alpha 0, will slide in + fade in
        for item in row0ItemViews where overflow.contains(item.absoluteIndex) {
            let target = targetRow0Frames[item.absoluteIndex]!
            item.isHidden = false
            item.alphaValue = 0
            // Start with left edge at collapsed window right edge
            item.frame = NSRect(
                x: contentSize.width,
                y: target.minY,
                width: target.width,
                height: target.height
            )
        }

        // Row 0 staying items: restore to expanded positions (layoutItems set them to collapsed)
        let expandedRow0Y = yForRow(0)
        for item in row0ItemViews {
            if !overflow.contains(item.absoluteIndex), let gridItem = expandedGridRows[0].items.first(where: { $0.candidateIndex == item.absoluteIndex }) {
                let w = CGFloat(gridItem.columnSpan) * expandedColumnWidth
                item.frame = NSRect(x: CGFloat(gridItem.columnStart) * expandedColumnWidth, y: expandedRow0Y, width: w, height: itemHeight)
            }
        }

        // Rows 1+ items: unhide at their current positions, will fade/slide out
        for (item, oldFrame) in oldExpandedFrames {
            item.isHidden = false
            item.frame = oldFrame
            item.alphaValue = 1
        }

        // Chevron: start at expanded right edge, will slide to final position + fade in
        let hasOverflow = displayCount > collapsedVisibleCount
        let expandedContentWidth = expandedColumnWidth * CGFloat(expandedPageSize)
        if hasOverflow {
            chevronView.isHidden = false
            chevronView.alphaValue = 0
            let chevronStartX = max(
                targetRow0Frames.values.map(\.maxX).max() ?? 0,
                expandedContentWidth - chevronView.intrinsicContentSize.width
            )
            chevronView.frame = NSRect(x: chevronStartX, y: yForRow(0), width: chevronView.intrinsicContentSize.width, height: itemHeight)
        }

        // Animate corner radius from uniform to pill
        let targetRightRadius = hasOverflow ? contentSize.height / 2 : Self.defaultCornerRadius
        animateCornerRadius(from: Self.defaultCornerRadius, to: targetRightRadius)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // Window resize
            self.animator().setFrame(targetWindowFrame, display: true)

            // Row 0 staying items: animate to collapsed frames
            for item in self.row0ItemViews where !overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {

                    item.animator().frame = target
                }
            }

            // Row 0 overflow items: slide in from right + fade in
            for item in self.row0ItemViews where overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {

                    item.animator().frame = target
                    item.animator().alphaValue = 1
                }
            }

            // Rows 1+ overflow duplicates: slide out to left + fade out
            for item in self.expandedItemViews where overflowDups.contains(item.absoluteIndex) {

                item.animator().alphaValue = 0
                var f = item.frame
                f.origin.x = -f.width
                item.animator().frame = f
            }

            // Rows 1+ other items: just fade out (window shrink clips them)
            for item in self.expandedItemViews where !overflowDups.contains(item.absoluteIndex) {
                // They stay in place, window shrinking clips them from below
            }

            // Chevron: slide to final position + fade in
            if hasOverflow {
                self.chevronView.animator().alphaValue = 1
                let chevronFinalX = targetRow0Frames.values.map(\.maxX).max() ?? 0
                var cf = self.chevronView.frame
                cf.origin.x = chevronFinalX
                self.chevronView.animator().frame = cf
            }

            // Row highlight fade out
            self.rowHighlightView.animator().alphaValue = 0

        }, completionHandler: { [weak self] in
            guard let self else { return }
            for item in self.expandedItemViews {
                item.isHidden = true
            }
            self.isAnimating = false
        })
    }

    // MARK: - Item View Lifecycle

    private func createItemView() -> CandidateItemView {
        let item = CandidateItemView()
        item.highlightColor = highlightColor
        return item
    }

    private func removeAllItemViews() {
        for item in row0ItemViews { item.removeFromSuperview() }
        for item in expandedItemViews { item.removeFromSuperview() }
        row0ItemViews.removeAll()
        expandedItemViews.removeAll()
    }

    // MARK: - Selection & Highlights

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
        if displayMode == .expanded {
            let newRowIdx = findGridPosition(of: selectedIndex)?.rowIndex
            if oldRowIdx != newRowIdx {
                updateRowHighlightsAndIndices()
                layoutHighlight()
                scrollSelectedRowIntoView()
            }
        }
        candidateDelegate?.candidateSelectionChanged(candidates[newIndex])
    }

    private func scrollSelectedRowIntoView() {
        guard displayMode == .expanded,
              let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return }
        let rowY = yForRow(rowIdx)
        let rowBottom = rowY + itemHeight
        let visible = scrollView.contentView.bounds

        if rowY < visible.minY {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if rowBottom > visible.maxY {
            let maxScrollY = scrollView.documentView!.frame.height - visible.height
            let targetY = min(rowBottom + 0.5 * itemHeight - visible.height, maxScrollY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func updateSelection() {
        let allItems = row0ItemViews + expandedItemViews
        for item in allItems {
            item.isHighlighted = item.absoluteIndex == selectedIndex
        }
    }

    private func updateRowHighlightsAndIndices() {
        guard displayMode == .expanded else { return }
        guard let (selectedRowIdx, _) = findGridPosition(of: selectedIndex) else { return }

        var rowForCandidate: [Int: Int] = [:]
        for (rowIndex, row) in gridRows.enumerated() {
            for gridItem in row.items {
                rowForCandidate[gridItem.candidateIndex] = rowIndex
            }
        }

        let allItems = row0ItemViews + expandedItemViews
        for item in allItems where !item.isHidden {
            if let rowIndex = rowForCandidate[item.absoluteIndex] {
                item.showIndex = rowIndex == selectedRowIdx
            }
        }
    }

    private func layoutHighlight() {
        guard displayMode == .expanded, let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return }
        let y = yForRow(rowIdx)
        rowHighlightView.frame = NSRect(x: 0, y: y, width: frame.width, height: itemHeight)
    }

    private func handleScrollerStyleChange() {
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        guard isVisible, displayMode == .expanded, !candidates.isEmpty else { return }
        let contentSize = layoutItems()
        let targetFrame = windowFrame(for: contentSize, reposition: false)
        setFrame(targetFrame, display: true)
        updateMaskImage()
    }

    // MARK: - Sizing

    private func windowFrame(for contentSize: NSSize, reposition: Bool) -> NSRect {
        if reposition, !lastShowNearRect.isEmpty {
            let topLeft = topLeftPoint(forWindowSize: contentSize, near: lastShowNearRect)
            return NSRect(
                x: topLeft.x,
                y: topLeft.y - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
        }
        let currentFrame = self.frame
        let screenRect = screen(containing: lastShowNearRect)?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var newOrigin = NSPoint(
            x: currentFrame.origin.x,
            y: currentFrame.maxY - contentSize.height
        )
        if newOrigin.y < screenRect.minY {
            if !lastShowNearRect.isEmpty {
                newOrigin.y = lastShowNearRect.maxY
            } else {
                newOrigin.y = screenRect.minY
            }
        }
        if newOrigin.x + contentSize.width > screenRect.maxX {
            newOrigin.x = screenRect.maxX - contentSize.width
        }
        return NSRect(origin: newOrigin, size: contentSize)
    }
}