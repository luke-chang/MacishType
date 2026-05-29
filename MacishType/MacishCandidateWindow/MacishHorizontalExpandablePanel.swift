import Cocoa

class MacishHorizontalExpandablePanel: MacishHorizontalBasePanel {

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

    // MARK: - State

    private(set) var widerExpandedColumns = true
    private(set) var moveOnExpand = false
    private var maxVisibleRows = 5

    private var displayMode: DisplayMode = .collapsed
    private var gridRows: [GridRow] = []
    private var expandedGridRows: [GridRow] = []
    private var expandedColumnWidth: CGFloat = 0
    private var expandedPageSize: Int = 0
    private var expandedRowsBuilt = false

    private var row0ItemViews: [MacishCandidateItemView] = []
    private var expandedItemViews: [MacishCandidateItemView] = []
    private var chevronView: MacishChevronView!

    override var allItemViews: [MacishCandidateItemView] { row0ItemViews + expandedItemViews }

    private var transitionCornerFrom: CGFloat = 0
    private var transitionCornerTo: CGFloat = 0

    private struct ItemAnimation {
        let item: MacishCandidateItemView
        let fromFrame: NSRect
        let toFrame: NSRect
        let fromAlpha: CGFloat
        let toAlpha: CGFloat
    }

    private struct TransitionState {
        let stayingItems: [ItemAnimation]
        let exitItems: [ItemAnimation]
        let enterItems: [ItemAnimation]
        let chevronFromFrame: NSRect
        let chevronToFrame: NSRect
        let chevronContentFromAlpha: CGFloat
        let chevronContentToAlpha: CGFloat
        let highlightFromAlpha: CGFloat
        let highlightToAlpha: CGFloat
        let isExpanding: Bool
    }

    private var transitionState: TransitionState?

    // MARK: - Init

    override init(style: CandidateWindow.Style) {
        super.init(style: style)

        chevronView = MacishChevronView(style: style)
        chevronView.onClick = { [weak self] in
            guard let self, !self.isAnimating, self.displayMode == .collapsed else { return }
            let collapsedCount = self.collapsedVisibleCount
            guard self.displayCount > collapsedCount else { return }
            self.expandWindow(animated: true)
        }
        candidateContainer.addSubview(chevronView)
    }

    // MARK: - Configuration

    override func updateFontSize(_ fontSize: CGFloat) {
        super.updateFontSize(fontSize)
        chevronView.updateFontSize(fontSize)
    }

    override func apply(_ configuration: CandidateWindowConfiguration, deferRender: Bool = false) {
        super.apply(configuration, deferRender: deferRender)
        maxVisibleRows = configuration.horizontalMaxVisibleRows
        widerExpandedColumns = configuration.widerExpandedColumns
        moveOnExpand = configuration.moveOnExpand
        if !deferRender, isVisible, !candidates.isEmpty {
            buildCandidateLayout()
            moveSelection(to: impl?.selectedIndex ?? -1, animated: false)
            if lastShowNearRect != .zero {
                show(near: lastShowNearRect)
            }
        }
    }

    // MARK: - Grid Computation

    private func computeExpandedGrid() -> [GridRow] {
        var rows: [GridRow] = []
        var currentRowItems: [GridItem] = []
        var currentColumn = 0

        for i in 0..<displayCount {
            let measuredWidth = MacishCandidateItemView.measureWidth(candidates[i])
            let span = max(1, min(expandedPageSize, Int(ceil(measuredWidth / expandedColumnWidth))))
            if currentColumn + span > expandedPageSize, !currentRowItems.isEmpty {
                rows.append(GridRow(items: currentRowItems))
                currentRowItems = []
                currentColumn = 0
            }
            currentRowItems.append(GridItem(
                candidateIndex: i, columnStart: currentColumn, columnSpan: span, measuredWidth: measuredWidth
            ))
            currentColumn += span
        }
        if !currentRowItems.isEmpty {
            rows.append(GridRow(items: currentRowItems))
        }
        return rows
    }

    private func computeCollapsedGrid() -> [GridRow] {
        var packedItems: [(candidateIndex: Int, width: CGFloat)] = []
        var usedWidth: CGFloat = 0

        for i in 0..<displayCount {
            if packedItems.count >= pageSize { break }
            let raw = MacishCandidateItemView.measureWidth(candidates[i])
            let w = max(baseColumnWidth, min(raw, maxPageSlotWidth))
            if usedWidth + w > maxPageSlotWidth, !packedItems.isEmpty { break }
            usedWidth += w
            packedItems.append((i, w))
        }

        let gridItems = packedItems.enumerated().map { pos, item in
            GridItem(candidateIndex: item.candidateIndex, columnStart: pos, columnSpan: 1, measuredWidth: item.width)
        }
        return [GridRow(items: gridItems)]
    }

    // MARK: - Layout

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
            chevronView.imageAlphaValue = 1
            chevronView.separatorAlphaValue = 1
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
            let viewByIndex = Dictionary(uniqueKeysWithValues: expandedItemViews.map { ($0.absoluteIndex, $0) })
            for rowIdx in 1..<expandedGridRows.count {
                for gridItem in expandedGridRows[rowIdx].items {
                    guard let item = viewByIndex[gridItem.candidateIndex] else { continue }
                    item.isHidden = false
                    let x = CGFloat(gridItem.columnStart) * expandedColumnWidth
                    let y = yForRow(rowIdx)
                    let w = CGFloat(gridItem.columnSpan) * expandedColumnWidth
                    item.frame = NSRect(x: x, y: y, width: w, height: itemHeight)
                }
            }
        } else {
            for item in expandedItemViews {
                item.isHidden = true
            }
        }

        let maxVisibleHeight = (CGFloat(maxVisibleRows) + 0.5) * itemHeight
            + CGFloat(maxVisibleRows - 1) * Self.separatorHeight
        let needsScrolling = displayMode == .expanded && contentHeight > maxVisibleHeight
        let windowHeight = needsScrolling ? maxVisibleHeight : contentHeight

        var windowWidth = contentWidth
        if needsScrolling {
            windowWidth += NSScroller.scrollerWidth(
                for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        }

        if displayMode == .expanded, let (rowIdx, _) = findGridPosition(of: selectedIndex) {
            let y = yForRow(rowIdx)
            rowHighlightView?.frame = NSRect(x: 0, y: y, width: windowWidth, height: itemHeight)
        }

        let totalContentHeight = needsScrolling ? contentHeight + 0.5 * itemHeight : contentHeight
        candidateContainer.frame.size = NSSize(width: contentWidth, height: totalContentHeight)
        return NSSize(width: windowWidth, height: windowHeight)
    }

    override func buildCandidateLayout() {
        resetState()
        removeAllItemViews()
        separatorViews.forEach { $0.removeFromSuperview() }
        separatorViews.removeAll()
        rowHighlightView?.alphaValue = 0

        guard !candidates.isEmpty else {
            setContentSize(NSSize(width: 0, height: 0))
            return
        }

        computeBaseMetrics()
        if widerExpandedColumns {
            expandedPageSize = pageSize - pageSize / 3
        } else {
            expandedPageSize = pageSize
        }
        expandedColumnWidth = maxPageSlotWidth / CGFloat(expandedPageSize)
        gridRows = computeCollapsedGrid()

        // Create row 0 items
        for (pos, gridItem) in gridRows[0].items.enumerated() {
            let item = createItemView()
            item.absoluteIndex = gridItem.candidateIndex
            item.configure(label: label(for: pos), candidate: candidates[gridItem.candidateIndex])
            candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
            row0ItemViews.append(item)
        }

        updateItemHighlights()

        let contentSize = layoutItems()
        setContentSize(contentSize)
        updateCorners()
    }

    // MARK: - Corner Radius Animation

    override func updateCorners() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        let showChevron = displayMode == .collapsed && displayCount > collapsedVisibleCount
        if showChevron {
            applyPillCorners(size: size)
        } else {
            applyUniformCorners()
        }
    }

    private func animateTransition(cornerFrom: CGFloat, cornerTo: CGFloat, frameTo: NSRect) {
        transitionCornerFrom = cornerFrom
        transitionCornerTo = cornerTo
        animateFrame(to: frameTo)
    }

    override func frameAnimationDidTick(t: CGFloat) {
        let size = frame.size
        if size.width > 0, size.height > 0 {
            switch style {
            case .sequoia:
                let radius = transitionCornerFrom + (transitionCornerTo - transitionCornerFrom) * t
                backdrop.applyAsymmetricCorners(
                    size: size, leftRadius: Self.defaultCornerRadius, rightRadius: radius
                )
            case .tahoe:
                if #unavailable(macOS 26) {
                    backdrop.applyUniformCorners(size: size, radius: itemHeight / 2)
                }
            }
        }

        guard let state = transitionState else { return }
        for anim in state.stayingItems {
            anim.item.frame = Self.interpolateRect(anim.fromFrame, anim.toFrame, t)
        }
        for anim in state.exitItems {
            anim.item.frame = Self.interpolateRect(anim.fromFrame, anim.toFrame, t)
            anim.item.alphaValue = anim.fromAlpha + (anim.toAlpha - anim.fromAlpha) * t
        }
        for anim in state.enterItems {
            anim.item.frame = Self.interpolateRect(anim.fromFrame, anim.toFrame, t)
            anim.item.alphaValue = anim.fromAlpha + (anim.toAlpha - anim.fromAlpha) * t
        }
        chevronView.frame = Self.interpolateRect(state.chevronFromFrame, state.chevronToFrame, t)
        chevronView.setContentAlpha(state.chevronContentFromAlpha + (state.chevronContentToAlpha - state.chevronContentFromAlpha) * t)
        rowHighlightView?.alphaValue = state.highlightFromAlpha + (state.highlightToAlpha - state.highlightFromAlpha) * t
    }

    override func frameAnimationDidFinish() {
        updateCorners()

        guard let state = transitionState else { return }
        if state.isExpanding {
            for anim in state.stayingItems {
                anim.item.frame = anim.toFrame
            }
            for anim in state.exitItems {
                anim.item.isHidden = true
            }
            chevronView.isHidden = true
            let hasOverflow = scrollView.documentView!.frame.height
                > scrollView.contentView.bounds.height
            scrollView.hasVerticalScroller = hasOverflow
            if hasOverflow, NSScroller.preferredScrollerStyle != .legacy {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scrollView.flashScrollers()
            }
            ensureSelectionVisible(animated: false)
        } else {
            for item in expandedItemViews {
                item.isHidden = true
            }
        }
        isAnimating = false
        transitionState = nil
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
                item.configure(label: label(for: pos), candidate: candidates[gridItem.candidateIndex])
            }
        }

        // Create rows 1+ items on first expand
        if !expandedRowsBuilt {
            for rowIndex in 1..<gridRows.count {
                let gridRow = gridRows[rowIndex]
                for (pos, gridItem) in gridRow.items.enumerated() {
                    let item = createItemView()
                    item.absoluteIndex = gridItem.candidateIndex
                    item.configure(label: label(for: pos), candidate: candidates[gridItem.candidateIndex])
                    candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
                    expandedItemViews.append(item)
                }
            }
            let expandedWidth = expandedColumnWidth * CGFloat(expandedPageSize)
                + NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
            let separatorWidth = max(frame.size.width, expandedWidth)
            ensureSeparators(count: max(expandedGridRows.count - 1, 0), width: separatorWidth)
            expandedRowsBuilt = true
            updateItemHighlights()
        }

        // Compute final layout (sets frames and isHidden states)
        let contentSize = layoutItems()

        // Reset scroll to top
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Update after layout so hidden state is correct
        updateRowHighlightsAndIndices()
        let targetWindowFrame = windowFrame(for: contentSize, reposition: true)

        if !animated {
            rowHighlightView?.alphaValue = 1
            setContentSize(contentSize)
            updateCorners()
            ensureSelectionVisible(animated: false)
            if lastShowNearRect != .zero { show(near: lastShowNearRect) }
            return
        }

        // --- Animated expand ---
        let (overflow, overflowDups) = computeOverflowSets()

        // Save target frames
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }
        var targetExpandedFrames: [Int: NSRect] = [:]
        for item in expandedItemViews {
            targetExpandedFrames[item.absoluteIndex] = item.frame
        }

        // Build animation state
        var stayingAnims: [ItemAnimation] = []
        var exitAnims: [ItemAnimation] = []
        var enterAnims: [ItemAnimation] = []

        for (item, oldFrame) in oldRow0Frames {
            if overflow.contains(item.absoluteIndex) {
                // Overflow items: fade out + slide right off-screen
                item.isHidden = false
                item.alphaValue = 1
                item.frame = oldFrame
                var exitFrame = oldFrame
                exitFrame.origin.x = collapsedWidth
                exitAnims.append(ItemAnimation(item: item, fromFrame: oldFrame, toFrame: exitFrame, fromAlpha: 1, toAlpha: 0))
            } else if let target = targetRow0Frames[item.absoluteIndex] {
                // Staying items: animate from collapsed to expanded position
                item.frame = oldFrame
                stayingAnims.append(ItemAnimation(item: item, fromFrame: oldFrame, toFrame: target, fromAlpha: 1, toAlpha: 1))
            }
        }

        for item in expandedItemViews {
            if overflowDups.contains(item.absoluteIndex), let target = targetExpandedFrames[item.absoluteIndex] {
                // Overflow duplicates: slide in from left
                item.alphaValue = 0
                var enterFrame = target
                enterFrame.origin.x = -(target.origin.x + target.width)
                enterAnims.append(ItemAnimation(item: item, fromFrame: enterFrame, toFrame: target, fromAlpha: 0, toAlpha: 1))
            } else {
                item.alphaValue = 1
            }
        }

        // Chevron animation state
        let chevronToFrame: NSRect
        if !oldChevronHidden {
            chevronView.isHidden = false
            chevronView.alphaValue = 1
            chevronView.frame = oldChevronFrame
            let chevronTargetX = max(
                targetRow0Frames.values.map(\.maxX).max() ?? 0,
                contentSize.width - chevronView.frame.width
            )
            chevronToFrame = NSRect(x: chevronTargetX, y: oldChevronFrame.origin.y, width: oldChevronFrame.width, height: oldChevronFrame.height)
        } else {
            chevronToFrame = oldChevronFrame
        }

        rowHighlightView?.alphaValue = 0
        scrollView.hasVerticalScroller = false

        transitionState = TransitionState(
            stayingItems: stayingAnims,
            exitItems: exitAnims,
            enterItems: enterAnims,
            chevronFromFrame: oldChevronFrame,
            chevronToFrame: chevronToFrame,
            chevronContentFromAlpha: oldChevronHidden ? 0 : 1,
            chevronContentToAlpha: 0,
            highlightFromAlpha: 0,
            highlightToAlpha: 1,
            isExpanding: true
        )

        isAnimating = true
        animateTransition(cornerFrom: frame.size.height / 2, cornerTo: Self.defaultCornerRadius,
                          frameTo: targetWindowFrame)
    }

    private func collapseWindow(animated: Bool) {
        // Capture state before changes
        let oldExpandedFrames = expandedItemViews.map { ($0, $0.frame) }
        let (overflow, overflowDups) = computeOverflowSets()

        displayMode = .collapsed
        gridRows = computeCollapsedGrid()

        // Reconfigure row 0 items with collapsed indices
        for (pos, gridItem) in gridRows[0].items.enumerated() {
            if let item = row0ItemViews.first(where: { $0.absoluteIndex == gridItem.candidateIndex }) {
                item.configure(label: label(for: pos), candidate: candidates[gridItem.candidateIndex])
            }
        }

        // Reset scroll to top
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Clamp selectedIndex
        let maxValid = gridRows[0].items.last?.candidateIndex ?? 0
        if selectedIndex > maxValid {
            moveSelection(to: maxValid)
        } else {
            updateItemHighlights()
        }

        // Compute final layout
        let contentSize = layoutItems()
        let targetWindowFrame = windowFrame(for: contentSize, reposition: true)

        if !animated {
            rowHighlightView?.alphaValue = 0
            for item in row0ItemViews { item.alphaValue = 1 }
            setContentSize(contentSize)
            updateCorners()
            if lastShowNearRect != .zero { show(near: lastShowNearRect) }
            return
        }

        // --- Animated collapse ---

        // Save target frames for row 0
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews where !item.isHidden {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }

        // Build animation state
        var stayingAnims: [ItemAnimation] = []
        var exitAnims: [ItemAnimation] = []
        var enterAnims: [ItemAnimation] = []

        // Row 0 staying items: animate from expanded to collapsed
        for item in row0ItemViews where !overflow.contains(item.absoluteIndex) {
            if let gridItem = expandedGridRows[0].items.first(where: { $0.candidateIndex == item.absoluteIndex }) {
                let expandedX = CGFloat(gridItem.columnStart) * expandedColumnWidth
                let expandedW = CGFloat(gridItem.columnSpan) * expandedColumnWidth
                let expandedFrame = NSRect(x: expandedX, y: item.frame.origin.y, width: expandedW, height: itemHeight)
                let collapsedFrame = item.frame
                item.frame = expandedFrame
                stayingAnims.append(ItemAnimation(item: item, fromFrame: expandedFrame, toFrame: collapsedFrame, fromAlpha: 1, toAlpha: 1))
            }
        }

        // Row 0 overflow items: slide in from right + fade in
        for item in row0ItemViews where overflow.contains(item.absoluteIndex) {
            let target = targetRow0Frames[item.absoluteIndex]!
            item.isHidden = false
            item.alphaValue = 0
            var enterFrame = target
            enterFrame.origin.x = contentSize.width
            item.frame = enterFrame
            enterAnims.append(ItemAnimation(item: item, fromFrame: enterFrame, toFrame: target, fromAlpha: 0, toAlpha: 1))
        }

        // Rows 1+ overflow duplicates: slide out to left + fade out
        for (item, oldFrame) in oldExpandedFrames {
            item.isHidden = false
            item.frame = oldFrame
            item.alphaValue = 1
            if overflowDups.contains(item.absoluteIndex) {
                var exitFrame = oldFrame
                exitFrame.origin.x = -(oldFrame.origin.x + oldFrame.width)
                exitAnims.append(ItemAnimation(item: item, fromFrame: oldFrame, toFrame: exitFrame, fromAlpha: 1, toAlpha: 0))
            }
        }

        // Chevron animation state
        let hasOverflow = displayCount > collapsedVisibleCount
        let expandedContentWidth = expandedColumnWidth * CGFloat(expandedPageSize)
        let chevronFromFrame: NSRect
        let chevronToFrame: NSRect
        if hasOverflow {
            chevronView.isHidden = false
            chevronView.alphaValue = 1
            chevronView.setContentAlpha(0)
            let chevronStartX = max(
                targetRow0Frames.values.map(\.maxX).max() ?? 0,
                expandedContentWidth - chevronView.intrinsicContentSize.width
            )
            let chevronSize = NSSize(width: chevronView.intrinsicContentSize.width, height: itemHeight)
            chevronFromFrame = NSRect(origin: NSPoint(x: chevronStartX, y: yForRow(0)), size: chevronSize)
            chevronView.frame = chevronFromFrame
            let chevronFinalX = targetRow0Frames.values.map(\.maxX).max() ?? 0
            chevronToFrame = NSRect(origin: NSPoint(x: chevronFinalX, y: yForRow(0)), size: chevronSize)
        } else {
            chevronFromFrame = chevronView.frame
            chevronToFrame = chevronView.frame
        }

        let targetRightRadius = hasOverflow ? contentSize.height / 2 : Self.defaultCornerRadius

        transitionState = TransitionState(
            stayingItems: stayingAnims,
            exitItems: exitAnims,
            enterItems: enterAnims,
            chevronFromFrame: chevronFromFrame,
            chevronToFrame: chevronToFrame,
            chevronContentFromAlpha: 0,
            chevronContentToAlpha: hasOverflow ? 1 : 0,
            highlightFromAlpha: 1,
            highlightToAlpha: 0,
            isExpanding: false
        )

        isAnimating = true
        animateTransition(cornerFrom: Self.defaultCornerRadius, cornerTo: targetRightRadius,
                          frameTo: targetWindowFrame)
    }

    // MARK: - Navigation

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        guard !candidates.isEmpty, !isAnimating else { return }

        let shouldMoveOnExpand = direction == .right || direction == .itemForward
            || ((direction == .itemBackward || direction == .left) && wrapping)
            || direction == .pageForward
            || (moveOnExpand && (direction == .down || direction == .pageDown))

        if displayMode == .collapsed, direction == .down || direction == .pageDown || direction == .pageForward {
            let collapsedCount = collapsedVisibleCount
            if displayCount > collapsedCount {
                if !expandedRowsBuilt {
                    expandedGridRows = computeExpandedGrid()
                }
                if shouldMoveOnExpand {
                    let jumpRows = direction == .pageDown ? maxVisibleRows - 1 : 1
                    let targetRowIdx = min(jumpRows, expandedGridRows.count - 1)
                    let targetRow = expandedGridRows[targetRowIdx]
                    let savedGridRows = gridRows
                    gridRows = expandedGridRows
                    if let (rowIdx, item) = findGridPosition(of: max(selectedIndex, 0)) {
                        if rowIdx == 0 {
                            if let target = findOverlappingItem(in: targetRow, columnStart: item.columnStart, columnEnd: item.columnStart + item.columnSpan) {
                                moveSelection(to: target)
                            } else {
                                moveSelection(to: targetRow.items.last!.candidateIndex)
                            }
                        } else {
                            moveSelection(to: targetRow.items.last!.candidateIndex)
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
                    moveSelection(to: target)
                } else {
                    expandWindow(animated: true)
                }
                return
            }
        }

        moveSelection(to: target)
    }

    private var collapsedVisibleCount: Int {
        gridRows.first?.items.count ?? 0
    }

    private static let collapseDirections: Set<NavigationDirection> = [.left, .up, .pageUp, .pageBackward, .itemBackward]

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
        in row: GridRow, columnStart: Int, columnEnd: Int, forward: Bool = true
    ) -> Int? {
        for (i, item) in row.items.enumerated() {
            let itemEnd = item.columnStart + item.columnSpan
            guard item.columnStart < columnEnd, itemEnd > columnStart else { continue }
            if !forward, item.columnStart < columnStart, i + 1 < row.items.count {
                let next = row.items[i + 1]
                if next.columnStart < columnEnd {
                    return next.candidateIndex
                }
            }
            return item.candidateIndex
        }
        return nil
    }

    private func gridNavigateVertical(direction: Int, rowCount: Int = 1) -> Int? {
        guard let (rowIdx, item) = findGridPosition(of: max(selectedIndex, 0)) else { return nil }
        let targetRowIdx = rowIdx + direction * rowCount
        let clampedRowIdx = max(0, min(targetRowIdx, gridRows.count - 1))
        guard clampedRowIdx != rowIdx else { return nil }

        let targetRow = gridRows[clampedRowIdx]
        return findOverlappingItem(
            in: targetRow,
            columnStart: item.columnStart,
            columnEnd: item.columnStart + item.columnSpan,
            forward: direction > 0
        ) ?? targetRow.items.last?.candidateIndex
    }

    // `startIndex` normalizes the -1 no-selection sentinel to 0 for offset
    // arithmetic; bound/dedup comparisons further down keep raw `selectedIndex`
    // so -1 still triggers a move on the first navigation.
    private func wrappingTarget(direction: NavigationDirection) -> Int? {
        let startIndex = max(selectedIndex, 0)
        switch direction {
        case .right where selectedIndex >= displayCount - 1:
            return 0
        case .itemForward where selectedIndex >= displayCount - 1:
            return 0
        case .left where selectedIndex <= 0:
            return displayCount - 1
        case .itemBackward where selectedIndex <= 0:
            return displayCount - 1
        case .down, .up, .pageForward, .pageBackward:
            guard let (rowIdx, item) = findGridPosition(of: startIndex) else { return nil }
            let colStart = item.columnStart
            let colEnd = colStart + item.columnSpan
            if direction == .down || direction == .pageForward, rowIdx >= gridRows.count - 1 {
                return findOverlappingItem(in: gridRows[0], columnStart: colStart, columnEnd: colEnd, forward: true)
            }
            if direction == .up || direction == .pageBackward, rowIdx <= 0 {
                let lastRow = gridRows[gridRows.count - 1]
                return findOverlappingItem(in: lastRow, columnStart: colStart, columnEnd: colEnd, forward: false)
            }
            return nil
        default:
            return nil
        }
    }

    private func navigationTarget(direction: NavigationDirection) -> Int? {
        let startIndex = max(selectedIndex, 0)
        switch direction {
        case .right:
            return startIndex + 1 < displayCount ? startIndex + 1 : nil
        case .left:
            return startIndex > 0 ? startIndex - 1 : nil
        case .down:
            return gridNavigateVertical(direction: 1)
        case .up:
            return gridNavigateVertical(direction: -1)
        case .home:
            guard let (rowIdx, _) = findGridPosition(of: startIndex) else { return nil }
            let first = gridRows[rowIdx].items.first!.candidateIndex
            return selectedIndex != first ? first : nil
        case .end:
            guard let (rowIdx, _) = findGridPosition(of: startIndex) else { return nil }
            let last = gridRows[rowIdx].items.last!.candidateIndex
            return selectedIndex != last ? last : nil
        case .pageUp:
            return gridNavigateVertical(direction: -1, rowCount: maxVisibleRows - 1)
        case .pageDown:
            return gridNavigateVertical(direction: 1, rowCount: maxVisibleRows - 1)
        case .itemForward:
            return startIndex + 1 < displayCount ? startIndex + 1 : nil
        case .itemBackward:
            return startIndex > 0 ? startIndex - 1 : nil
        case .pageForward:
            return gridNavigateVertical(direction: 1)
        case .pageBackward:
            return gridNavigateVertical(direction: -1)
        }
    }

    // MARK: - Selection & Highlights

    override func updateItemHighlights() {
        super.updateItemHighlights()
        if displayMode == .expanded {
            updateRowHighlightsAndIndices()
            layoutHighlight()
        }
    }

    override func ensureSelectionVisible(animated: Bool) {
        if displayMode == .collapsed,
           selectedIndex >= collapsedVisibleCount,
           displayCount > collapsedVisibleCount {
            expandWindow(animated: animated)
            return
        }
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

    private func updateRowHighlightsAndIndices() {
        guard displayMode == .expanded else { return }
        // selectedRowIdx == nil when no selection (-1 sentinel) — no row
        // claims showIndex.
        let selectedRowIdx = findGridPosition(of: selectedIndex)?.rowIndex

        var rowForCandidate: [Int: Int] = [:]
        for (rowIndex, row) in gridRows.enumerated() {
            for gridItem in row.items {
                rowForCandidate[gridItem.candidateIndex] = rowIndex
            }
        }

        for item in allItemViews where !item.isHidden {
            if let rowIndex = rowForCandidate[item.absoluteIndex] {
                item.showIndex = rowIndex == selectedRowIdx
            }
        }
    }

    private func layoutHighlight() {
        guard displayMode == .expanded else { return }
        // Hide the row highlight bar when there's no selection so it doesn't
        // sit at a stale row from the previous selection.
        guard let (rowIdx, _) = findGridPosition(of: selectedIndex) else {
            rowHighlightView?.alphaValue = 0
            return
        }
        rowHighlightView?.alphaValue = 1
        let y = yForRow(rowIdx)
        rowHighlightView?.frame = NSRect(x: 0, y: y, width: frame.width, height: itemHeight)
    }

    // MARK: - Commit

    override func commitCandidate(at index: Int) {
        guard isVisible else { return }
        guard index >= 0 else { return }

        // -1 (no selection) is treated as row 0 so number-key commit still
        // works in the suspend state (e.g. associated mode).
        guard let (rowIdx, _) = findGridPosition(of: max(selectedIndex, 0)) else { return }
        let row = gridRows[rowIdx]
        guard index < row.items.count else { return }

        let candidateIndex = row.items[index].candidateIndex
        guard candidateIndex < candidates.count else { return }
        let chosen = candidates[candidateIndex]
        impl.candidateDelegate?.candidateConfirmed(
            chosen.text, absoluteIndex: candidateIndex, raw: chosen)
    }

    // MARK: - Scroller Style

    override func handleScrollerStyleChange() {
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        guard isVisible, displayMode == .expanded, !candidates.isEmpty else { return }
        let contentSize = layoutItems()
        let targetFrame = windowFrame(for: contentSize, reposition: false)
        setFrame(targetFrame, display: true)
        updateCorners()
    }

    // MARK: - Reset

    private func resetState() {
        displayMode = .collapsed
        isAnimating = false
        transitionState = nil
        expandedGridRows = []
        expandedRowsBuilt = false
        stopFrameAnimation()
    }

    // MARK: - Overflow Helpers

    private func computeOverflowSets() -> (overflow: Set<Int>, duplicates: Set<Int>) {
        let expandedRow0 = Set(expandedGridRows[0].items.map(\.candidateIndex))
        let allRow0 = Set(row0ItemViews.map(\.absoluteIndex))
        let overflow = allRow0.subtracting(expandedRow0)
        let duplicates = Set(expandedItemViews.filter { overflow.contains($0.absoluteIndex) }.map(\.absoluteIndex))
        return (overflow, duplicates)
    }

    // MARK: - Item View Lifecycle

    private func removeAllItemViews() {
        for item in row0ItemViews { item.removeFromSuperview() }
        for item in expandedItemViews { item.removeFromSuperview() }
        row0ItemViews.removeAll()
        expandedItemViews.removeAll()
    }
}
