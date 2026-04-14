import Cocoa

class SequoiaHorizontalExpandablePanel: SequoiaHorizontalBasePanel {

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

    private var row0ItemViews: [SequoiaCandidateItemView] = []
    private var expandedItemViews: [SequoiaCandidateItemView] = []
    private var chevronView: SequoiaChevronView!

    override var allItemViews: [SequoiaCandidateItemView] { row0ItemViews + expandedItemViews }

    private var transitionCornerFrom: CGFloat = 0
    private var transitionCornerTo: CGFloat = 0

    // MARK: - Init

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        chevronView = SequoiaChevronView()
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

    override func apply(_ configuration: CandidateWindowConfiguration) {
        super.apply(configuration)
        maxVisibleRows = configuration.horizontalMaxVisibleRows
        widerExpandedColumns = configuration.widerExpandedColumns
        moveOnExpand = configuration.moveOnExpand
        if isVisible, !candidates.isEmpty {
            buildCandidateLayout()
            restoreSelection(to: impl?.selectedIndex ?? 0)
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
            let w = SequoiaCandidateItemView.measureWidth(index: indexBase, candidate: candidates[i])
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
            let raw = SequoiaCandidateItemView.measureWidth(index: packedItems.count + indexBase, candidate: candidates[i])
            let w = max(baseColumnWidth, min(raw, maxWidth))
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
            rowHighlightView.frame = NSRect(x: 0, y: y, width: windowWidth, height: itemHeight)
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
        rowHighlightView.alphaValue = 0

        guard !candidates.isEmpty else {
            setContentSize(NSSize(width: 0, height: 0))
            return
        }

        computeBaseMetrics()
        if widerExpandedColumns {
            expandedPageSize = pageSize - pageSize / 3
            expandedColumnWidth = baseColumnWidth * CGFloat(pageSize) / CGFloat(expandedPageSize)
        } else {
            expandedPageSize = pageSize
            expandedColumnWidth = baseColumnWidth
        }
        gridRows = computeCollapsedGrid()

        // Create row 0 items
        for (pos, gridItem) in gridRows[0].items.enumerated() {
            let item = createItemView()
            item.absoluteIndex = gridItem.candidateIndex
            item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
            candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
            row0ItemViews.append(item)
        }

        updateItemHighlights()

        let contentSize = layoutItems()
        setContentSize(contentSize)
        updateHorizontalMaskImage()
    }

    // MARK: - Corner Radius Animation

    private func updateHorizontalMaskImage() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        let showChevron = displayMode == .collapsed && displayCount > collapsedVisibleCount
        if showChevron {
            applyPillCorners(size: size)
        } else {
            applyUniformCorners()
        }
    }

    override func updateMaskImage() {
        updateHorizontalMaskImage()
    }

    private func animateTransition(cornerFrom: CGFloat, cornerTo: CGFloat, frameTo: NSRect) {
        transitionCornerFrom = cornerFrom
        transitionCornerTo = cornerTo
        animateFrame(to: frameTo)
    }

    private func makeAnimation(keyPath: String, from: CGFloat, to: CGFloat, persist: Bool = false) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = animationDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if persist {
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
        }
        return anim
    }

    override func frameAnimationDidTick(t: CGFloat) {
        let radius = transitionCornerFrom + (transitionCornerTo - transitionCornerFrom) * t
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        visualEffectView.maskImage = .asymmetricCornerMask(
            size: size, leftRadius: Self.defaultCornerRadius, rightRadius: radius
        )
    }

    override func frameAnimationDidFinish() {
        updateHorizontalMaskImage()
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
            rowHighlightView.alphaValue = 1
            setContentSize(contentSize)
            updateHorizontalMaskImage()
            ensureSelectionVisible()
            if lastShowNearRect != .zero { show(near: lastShowNearRect) }
            return
        }

        // --- Animated expand ---
        let (overflow, overflowDups) = computeOverflowSets()
        // Save target frames, then set initial animation state
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }
        var targetExpandedFrames: [Int: NSRect] = [:]
        for item in expandedItemViews {
            targetExpandedFrames[item.absoluteIndex] = item.frame
        }

        // Row 0 staying items: restore to old frames (model stays within window)
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

        // Animate window frame, corner radius, and mask together
        animateTransition(cornerFrom: frame.size.height / 2, cornerTo: Self.defaultCornerRadius,
                          frameTo: targetWindowFrame)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // Row 0 staying items: animate from collapsed to expanded via transform
            for (item, oldFrame) in oldRow0Frames where !overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {
                    let dx = target.origin.x - oldFrame.origin.x
                    item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: 0, to: dx, persist: true), forKey: "slideToExpanded")
                    item.layer?.add(self.makeAnimation(keyPath: "bounds.size.width", from: oldFrame.size.width, to: target.size.width, persist: true), forKey: "width")
                }
            }

            // Row 0 overflow items: fade out + slide right via layer transform
            for item in self.row0ItemViews where overflow.contains(item.absoluteIndex) {
                item.animator().alphaValue = 0
                item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: 0, to: collapsedWidth - item.frame.origin.x), forKey: "slideRight")
            }

            // Rows 1+ overflow duplicates: slide in from left via transform + fade in
            for item in self.expandedItemViews where overflowDups.contains(item.absoluteIndex) {
                if let target = targetExpandedFrames[item.absoluteIndex] {
                    item.animator().alphaValue = 1
                    item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: -(target.origin.x + target.width), to: 0), forKey: "slideIn")
                }
            }

            // Chevron: fade out, track right edge
            if !oldChevronHidden {
                self.chevronView.animateContentAlpha(to: 0)
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
            // Snap staying items to expanded frames and clear animations
            for item in self.row0ItemViews where !overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {
                    item.layer?.removeAllAnimations()
                    item.frame = target
                    item.layer?.transform = CATransform3DIdentity
                }
            }
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
            self.ensureSelectionVisible()
        })
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
                item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
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
            rowHighlightView.alphaValue = 0
            for item in row0ItemViews { item.alphaValue = 1 }
            setContentSize(contentSize)
            updateHorizontalMaskImage()
            if lastShowNearRect != .zero { show(near: lastShowNearRect) }
            return
        }

        // --- Animated collapse ---

        // Save target frames for row 0
        var targetRow0Frames: [Int: NSRect] = [:]
        for item in row0ItemViews where !item.isHidden {
            targetRow0Frames[item.absoluteIndex] = item.frame
        }

        // Row 0 overflow items: place at target, offset visually via transform
        for item in row0ItemViews where overflow.contains(item.absoluteIndex) {
            let target = targetRow0Frames[item.absoluteIndex]!
            item.isHidden = false
            item.alphaValue = 0
            item.frame = target
        }

        // Row 0 staying items: keep at collapsed frames, transform will handle visual offset

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
            chevronView.alphaValue = 1
            chevronView.imageAlphaValue = 0
            chevronView.separatorAlphaValue = 0
            let chevronStartX = max(
                targetRow0Frames.values.map(\.maxX).max() ?? 0,
                expandedContentWidth - chevronView.intrinsicContentSize.width
            )
            chevronView.frame = NSRect(x: chevronStartX, y: yForRow(0), width: chevronView.intrinsicContentSize.width, height: itemHeight)
        }

        // Animate window frame, corner radius, and mask together
        let targetRightRadius = hasOverflow ? contentSize.height / 2 : Self.defaultCornerRadius
        animateTransition(cornerFrom: Self.defaultCornerRadius, cornerTo: targetRightRadius,
                          frameTo: targetWindowFrame)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // Row 0 staying items: slide from expanded to collapsed via transform.
            // No fillMode needed — model frame is already at collapsed (the end state).
            for item in self.row0ItemViews where !overflow.contains(item.absoluteIndex) {
                if let gridItem = self.expandedGridRows[0].items.first(where: { $0.candidateIndex == item.absoluteIndex }) {
                    let expandedX = CGFloat(gridItem.columnStart) * self.expandedColumnWidth
                    let expandedW = CGFloat(gridItem.columnSpan) * self.expandedColumnWidth
                    let dx = expandedX - item.frame.origin.x
                    item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: dx, to: 0), forKey: "slideToCollapsed")
                    item.layer?.add(self.makeAnimation(keyPath: "bounds.size.width", from: expandedW, to: item.frame.size.width), forKey: "width")
                }
            }

            // Row 0 overflow items: slide in from right via transform + fade in
            for item in self.row0ItemViews where overflow.contains(item.absoluteIndex) {
                if let target = targetRow0Frames[item.absoluteIndex] {
                    item.animator().alphaValue = 1
                    item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: contentSize.width - target.origin.x, to: 0), forKey: "slideIn")
                }
            }

            // Rows 1+ overflow duplicates: slide out to left via transform + fade out
            for item in self.expandedItemViews where overflowDups.contains(item.absoluteIndex) {
                item.animator().alphaValue = 0
                item.layer?.add(self.makeAnimation(keyPath: "transform.translation.x", from: 0, to: -(item.frame.origin.x + item.frame.width)), forKey: "slideLeft")
            }

            // Chevron: slide to final position + fade in
            if hasOverflow {
                self.chevronView.animateContentAlpha(to: 1)
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
                    if let (rowIdx, item) = findGridPosition(of: selectedIndex) {
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
                }
                expandWindow(animated: true)
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
        guard let (rowIdx, item) = findGridPosition(of: selectedIndex) else { return nil }
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

    private func wrappingTarget(direction: NavigationDirection) -> Int? {
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
            guard let (rowIdx, item) = findGridPosition(of: selectedIndex) else { return nil }
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
            return gridNavigateVertical(direction: -1, rowCount: maxVisibleRows - 1)
        case .pageDown:
            return gridNavigateVertical(direction: 1, rowCount: maxVisibleRows - 1)
        case .itemForward:
            return selectedIndex + 1 < displayCount ? selectedIndex + 1 : nil
        case .itemBackward:
            return selectedIndex > 0 ? selectedIndex - 1 : nil
        case .pageForward:
            return gridNavigateVertical(direction: 1)
        case .pageBackward:
            return gridNavigateVertical(direction: -1)
        }
    }

    // MARK: - Selection & Highlights

    override func restoreSelection(to index: Int) {
        let target = min(index, max(displayCount - 1, 0))
        if displayMode == .collapsed, target >= collapsedVisibleCount, displayCount > collapsedVisibleCount {
            moveSelection(to: target)
            expandWindow(animated: false)
        } else {
            moveSelection(to: target)
        }
    }

    override func moveSelection(to newIndex: Int) {
        let oldRowIdx = findGridPosition(of: selectedIndex)?.rowIndex
        super.moveSelection(to: newIndex)
        if displayMode == .expanded {
            let newRowIdx = findGridPosition(of: selectedIndex)?.rowIndex
            if oldRowIdx != newRowIdx {
                updateRowHighlightsAndIndices()
                layoutHighlight()
                ensureSelectionVisible()
            }
        }
    }

    override func ensureSelectionVisible() {
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
        guard let (selectedRowIdx, _) = findGridPosition(of: selectedIndex) else { return }

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
        guard displayMode == .expanded, let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return }
        let y = yForRow(rowIdx)
        rowHighlightView.frame = NSRect(x: 0, y: y, width: frame.width, height: itemHeight)
    }

    // MARK: - Commit

    override func commitCandidateForDigit(_ digit: Int) {
        guard isVisible else { return }
        let itemOffset = digit - indexBase
        guard itemOffset >= 0 else { return }

        guard let (rowIdx, _) = findGridPosition(of: selectedIndex) else { return }
        let row = gridRows[rowIdx]
        guard itemOffset < row.items.count else { return }

        let candidateIndex = row.items[itemOffset].candidateIndex
        guard candidateIndex < candidates.count else { return }
        impl.candidateDelegate?.candidateConfirmed(candidates[candidateIndex])
    }

    // MARK: - Scroller Style

    override func handleScrollerStyleChange() {
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        guard isVisible, displayMode == .expanded, !candidates.isEmpty else { return }
        let contentSize = layoutItems()
        let targetFrame = windowFrame(for: contentSize, reposition: false)
        setFrame(targetFrame, display: true)
        updateHorizontalMaskImage()
    }

    // MARK: - Reset

    private func resetState() {
        displayMode = .collapsed
        isAnimating = false
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
