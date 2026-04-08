import Cocoa

class SequoiaVerticalPanel: SequoiaBasePanel {

    // MARK: - State

    private var itemViews: [SequoiaCandidateItemView] = []
    private var anchorIndex = 0
    private var isFullyRendered = false
    private var initialContentWidth: CGFloat = 0
    private var maxContentWidth: CGFloat = 0
    private var naturalContentHeight: CGFloat = 0
    private var minVisibleRows = 0
    private var boundsObserver: (any NSObjectProtocol)?

    override var allItemViews: [SequoiaCandidateItemView] { itemViews }

    // MARK: - Init

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.scrollViewDidScroll()
        }
    }

    @MainActor deinit {
        if let observer = boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    override func apply(_ configuration: CandidateWindowConfiguration) {
        lastAppliedConfiguration = configuration
        indexBase = configuration.indexBase
        pageSize = configuration.pageSize
        minVisibleRows = configuration.verticalMinVisibleRows ?? configuration.pageSize
        animationDuration = configuration.animationDuration
        if isVisible, !candidates.isEmpty {
            rebuildLayout()
        }
    }

    // MARK: - Candidates

    override func updateCandidates(_ newCandidates: [String]) {
        candidates = newCandidates
        selectedIndex = 0
        isFullyRendered = false
        anchorIndex = -1
        rebuildLayout()
    }

    // MARK: - Layout

    private var rowHeight: CGFloat { itemHeight + Self.separatorHeight }

    private func rebuildLayout() {
        removeAllItemViews()
        separatorViews.forEach { $0.removeFromSuperview() }
        separatorViews.removeAll()
        isFullyRendered = false
        anchorIndex = -1

        guard !candidates.isEmpty else {
            setContentSize(.zero)
            return
        }

        computeBaseMetrics()

        // Width: measure top-3 by character count
        let contentWidth = measureContentWidth(candidates: candidates)
        initialContentWidth = contentWidth
        maxContentWidth = baseColumnWidth * CGFloat(pageSize)

        let hasOverflow = displayCount > pageSize
        let scrollerReserve = hasOverflow
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        let itemWidth = min(contentWidth, maxContentWidth)
        let windowWidth = itemWidth + scrollerReserve

        // Fixed window height
        let visibleRows = max(min(displayCount, pageSize), minVisibleRows)
        let bottomPeek: CGFloat = hasOverflow ? 0.5 * itemHeight : 0
        let windowHeight = CGFloat(visibleRows) * itemHeight
            + CGFloat(max(visibleRows - 1, 0)) * Self.separatorHeight
            + bottomPeek

        // Natural content height: all items + 0.5 row bottom padding.
        // Page navigation may temporarily expand beyond this in scrollToRow().
        let contentHeight = CGFloat(displayCount) * itemHeight
            + CGFloat(max(displayCount - 1, 0)) * Self.separatorHeight
            + bottomPeek
        naturalContentHeight = contentHeight

        candidateContainer.frame.size = NSSize(width: windowWidth, height: contentHeight)

        // Item views span full windowWidth (highlight extends to edge).
        // reservesScrollerSpace adds internal trailing padding so text
        // stays clear of the overlay scrollbar area.
        let initialCount = min(pageSize + 2, displayCount)
        for i in 0..<initialCount {
            let item = createItemView()
            item.absoluteIndex = i
            item.reservesScrollerSpace = hasOverflow
            item.frame = NSRect(x: 0, y: yForRow(i), width: windowWidth, height: itemHeight)
            candidateContainer.addSubview(item)
            itemViews.append(item)
        }
        isFullyRendered = initialCount >= displayCount

        ensureSeparators(count: max(displayCount - 1, 0), width: windowWidth)

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        updateNumbering()
        updateSelection()
        updateMaskImage()

        let windowSize = NSSize(width: windowWidth, height: windowHeight)
        let targetFrame = windowFrame(for: windowSize, reposition: !lastShowNearRect.isEmpty)
        setFrame(targetFrame, display: true)

        if hasOverflow, NSScroller.preferredScrollerStyle != .legacy {
            scrollView.flashScrollers()
        }
    }

    private func measureContentWidth(candidates: [String]) -> CGFloat {
        // Find top-3 candidates by character count, measure their actual pixel width
        let sorted = candidates.prefix(displayCount)
            .enumerated()
            .sorted { $0.element.count > $1.element.count }
            .prefix(3)

        var maxWidth = baseColumnWidth
        for (_, candidate) in sorted {
            let w = SequoiaCandidateItemView.measureWidth(index: indexBase, candidate: candidate)
            maxWidth = max(maxWidth, w)
        }
        return maxWidth
    }

    // MARK: - Full Render

    private func performFullRender() {
        guard !isFullyRendered else { return }
        isFullyRendered = true

        let containerWidth = candidateContainer.frame.width
        for i in itemViews.count..<displayCount {
            let item = createItemView()
            item.absoluteIndex = i
            item.reservesScrollerSpace = true
            item.frame = NSRect(x: 0, y: yForRow(i), width: containerWidth, height: itemHeight)
            candidateContainer.addSubview(item)
            itemViews.append(item)
        }

        // Re-measure actual max width across all candidates
        var actualMaxWidth = initialContentWidth
        for i in 0..<displayCount {
            let w = SequoiaCandidateItemView.measureWidth(index: indexBase, candidate: candidates[i])
            actualMaxWidth = max(actualMaxWidth, w)
        }

        let cappedWidth = min(actualMaxWidth, maxContentWidth)
        if cappedWidth > initialContentWidth {
            let scrollerReserve = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            let newWindowWidth = cappedWidth + scrollerReserve

            candidateContainer.frame.size.width = newWindowWidth
            for item in itemViews {
                item.frame.size.width = newWindowWidth
            }
            for sep in separatorViews where !sep.isHidden {
                sep.frame.size.width = newWindowWidth
            }

            let newSize = NSSize(width: newWindowWidth, height: frame.height)
            let targetFrame = windowFrame(for: newSize, reposition: false)

            isAnimating = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        }

        updateNumbering()
        updateSelection()
    }

    // MARK: - Scroll Handling

    private func scrollViewDidScroll() {
        let scrollOffset = scrollView.contentView.bounds.origin.y

        // Trigger full render when pageSize+1 item's bottom half enters viewport
        if !isFullyRendered, scrollOffset > 0.5 * rowHeight {
            performFullRender()
        }

        // Shrink container back toward natural height (never expand — only scrollToRow expands)
        let viewportHeight = scrollView.contentView.bounds.height
        let neededHeight = scrollOffset + viewportHeight
        let targetHeight = max(naturalContentHeight, neededHeight)
        if targetHeight < candidateContainer.frame.height {
            candidateContainer.frame.size.height = targetHeight
        }

        updateNumbering()
    }

    // MARK: - Numbering

    private func updateNumbering() {
        let scrollOffset = max(0, scrollView.contentView.bounds.origin.y)
        let newAnchor = max(0, Int(floor((scrollOffset + 0.5 * itemHeight) / rowHeight)))
        guard newAnchor != anchorIndex else { return }
        anchorIndex = newAnchor

        let numberedStart = anchorIndex
        let numberedEnd = min(anchorIndex + pageSize, displayCount)

        for item in itemViews {
            let i = item.absoluteIndex
            if i >= numberedStart, i < numberedEnd {
                item.showIndex = true
                item.configure(index: (i - anchorIndex) + indexBase, candidate: candidates[i])
            } else {
                item.configure(index: 0, candidate: candidates[i])
                item.showIndex = false
            }
        }
    }

    // MARK: - Navigation

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        guard !candidates.isEmpty else { return }

        switch direction {
        case .up, .itemBackward:
            let target: Int?
            if selectedIndex > 0 {
                target = selectedIndex - 1
            } else {
                target = wrapping ? displayCount - 1 : nil
            }
            if let target {
                moveSelection(to: target)
                ensureSelectionVisible()
            }

        case .down, .itemForward:
            let target: Int?
            if selectedIndex < displayCount - 1 {
                target = selectedIndex + 1
            } else {
                target = wrapping ? 0 : nil
            }
            if let target {
                moveSelection(to: target)
                ensureSelectionVisible()
            }

        case .right, .pageDown, .pageForward:
            ensureSelectionVisible()
            let visualOffset = selectedIndex - anchorIndex
            let newAnchor = anchorIndex + pageSize
            if newAnchor < displayCount {
                let target = min(newAnchor + visualOffset, displayCount - 1)
                moveSelection(to: target)
                scrollToRow(target, atVisiblePosition: min(visualOffset, target - newAnchor))
            } else if wrapping {
                moveSelection(to: 0)
                scrollToRow(0, atVisiblePosition: 0)
            } else if selectedIndex < displayCount - 1 {
                moveSelection(to: displayCount - 1)
                ensureSelectionVisible()
            }

        case .left, .pageUp, .pageBackward:
            ensureSelectionVisible()
            let visualOffset = selectedIndex - anchorIndex
            let newAnchor = anchorIndex - pageSize
            if newAnchor >= 0 {
                let target = newAnchor + visualOffset
                moveSelection(to: target)
                scrollToRow(target, atVisiblePosition: visualOffset)
            } else if anchorIndex > 0 {
                let target = min(visualOffset, displayCount - 1)
                moveSelection(to: target)
                scrollToRow(target, atVisiblePosition: min(visualOffset, target))
            } else if wrapping {
                moveSelection(to: displayCount - 1)
                ensureSelectionVisible()
            } else if selectedIndex > 0 {
                moveSelection(to: 0)
                scrollToRow(0, atVisiblePosition: 0)
            }

        case .home:
            if selectedIndex != 0 {
                moveSelection(to: 0)
                scrollToRow(0, atVisiblePosition: 0)
            }

        case .end:
            if selectedIndex != displayCount - 1 {
                moveSelection(to: displayCount - 1)
                ensureSelectionVisible()
            }
        }
    }

    override func ensureSelectionVisible() {
        guard selectedIndex < anchorIndex || selectedIndex >= anchorIndex + pageSize else { return }

        let itemTop = yForRow(selectedIndex)
        let itemBottom = itemTop + itemHeight
        let visible = scrollView.contentView.bounds

        if itemTop < visible.minY {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: itemTop))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if itemBottom > visible.maxY {
            let maxScrollY = candidateContainer.frame.height - visible.height
            let targetY = min(itemBottom + 0.5 * itemHeight - visible.height, maxScrollY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        updateNumbering()
    }

    private func scrollToRow(_ index: Int, atVisiblePosition position: Int) {
        let targetAnchor = max(0, index - position)
        let targetY = CGFloat(targetAnchor) * rowHeight
        let viewportHeight = scrollView.contentView.bounds.height

        // Expand container if page navigation needs to go beyond natural range
        let neededHeight = targetY + viewportHeight
        if neededHeight > candidateContainer.frame.height {
            candidateContainer.frame.size.height = neededHeight
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }



    // MARK: - Commit

    override func commitCandidateForDigit(_ digit: Int) {
        guard isVisible else { return }
        let offset = digit - indexBase
        guard offset >= 0, offset < pageSize else { return }
        let candidateIndex = anchorIndex + offset
        guard candidateIndex < displayCount else { return }
        impl?.candidateDelegate?.candidateConfirmed(candidates[candidateIndex])
    }

    // MARK: - Scroller Style

    override func handleScrollerStyleChange() {
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        guard isVisible, !candidates.isEmpty else { return }
        rebuildLayout()
    }

    // MARK: - Item View Lifecycle

    private func removeAllItemViews() {
        for item in itemViews { item.removeFromSuperview() }
        itemViews.removeAll()
    }
}
