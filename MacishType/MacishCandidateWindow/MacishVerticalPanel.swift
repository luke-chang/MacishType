import Cocoa

class MacishVerticalPanel: MacishBasePanel {

    // MARK: - State

    private static let overlayVisualGap: CGFloat = 2

    private var itemViews: [MacishCandidateItemView] = []
    private var anchorIndex = 0
    private var isFullyRendered = false
    private var initialContentWidth: CGFloat = 0
    private var maxContentWidth: CGFloat = 0
    private var naturalContentHeight: CGFloat = 0
    private var minVisibleRows = 0
    private var boundsObserver: (any NSObjectProtocol)?

    override var allItemViews: [MacishCandidateItemView] { itemViews }

    // MARK: - Init

    override init(style: CandidateWindow.Style) {
        super.init(style: style)
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

    override func apply(_ configuration: CandidateWindowConfiguration, deferRender: Bool = false) {
        super.apply(configuration, deferRender: deferRender)
        minVisibleRows = configuration.verticalMinVisibleRows ?? configuration.pageSize
        if !deferRender, isVisible, !candidates.isEmpty {
            buildCandidateLayout()
            restoreSelection(to: impl?.selectedIndex ?? 0)
        }
    }

    // MARK: - Layout

    private var rowHeight: CGFloat { itemHeight + Self.separatorHeight }

    // Always repositions to avoid animated position correction that covers the composing text.
    override func buildCandidateLayout() {
        isFullyRendered = false
        anchorIndex = -1
        removeAllItemViews()
        separatorViews.forEach { $0.removeFromSuperview() }
        separatorViews.removeAll()

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
        let cappedWidth = min(contentWidth, maxContentWidth)
        let (windowWidth, itemWidth, itemTrailing) = scrollerGeometry(
            contentWidth: cappedWidth, hasOverflow: hasOverflow)

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

        candidateContainer.frame.size = NSSize(width: itemWidth, height: contentHeight)

        let initialCount = min(pageSize + 2, displayCount)
        for i in 0..<initialCount {
            let item = createItemView()
            item.absoluteIndex = i
            item.trailingInset = itemTrailing
            item.frame = NSRect(x: 0, y: yForRow(i), width: itemWidth, height: itemHeight)
            candidateContainer.addSubview(item)
            itemViews.append(item)
        }
        isFullyRendered = initialCount >= displayCount

        ensureSeparators(count: max(displayCount - 1, 0), width: itemWidth)
        if style == .tahoe {
            let inset = round(8 * configuration.fontSize / 16)
            for sep in separatorViews { sep.horizontalInset = inset }
        }

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        updateNumbering()
        updateItemHighlights()

        let windowSize = NSSize(width: windowWidth, height: windowHeight)
        let targetFrame = windowFrame(for: windowSize, reposition: isVisible && lastShowNearRect != .zero)
        setFrame(targetFrame, display: true)
        updateCorners()

        if hasOverflow, NSScroller.preferredScrollerStyle != .legacy {
            scrollView.flashScrollers()
        }
    }

    private func measureContentWidth(candidates: [Candidate]) -> CGFloat {
        // Find top-3 candidates by combined text+annotation length, measure their actual pixel width
        func combinedLength(_ candidate: Candidate) -> Int {
            candidate.text.count + (candidate.annotation?.count ?? 0)
        }
        let sorted = candidates.prefix(displayCount)
            .enumerated()
            .sorted { combinedLength($0.element) > combinedLength($1.element) }
            .prefix(3)

        var maxWidth = baseColumnWidth
        for (_, candidate) in sorted {
            let measuredWidth = MacishCandidateItemView.measureWidth(candidate)
            maxWidth = max(maxWidth, measuredWidth)
        }
        return maxWidth
    }

    // Computes geometry honoring the current scroller style.
    // - Legacy: item stays inside clipView so rounded corners aren't cut off;
    //   scrollbar sits in the [itemWidth, windowWidth] gap outside.
    // - Overlay: item fills windowWidth (clipView = windowWidth), trailing
    //   inset keeps text clear of the scrollbar with a small visual gap.
    private func scrollerGeometry(contentWidth: CGFloat, hasOverflow: Bool)
        -> (windowWidth: CGFloat, itemWidth: CGFloat, itemTrailing: CGFloat) {
        let naturalPadding = MacishCandidateItemView.defaultTrailingPadding
        guard hasOverflow else { return (contentWidth, contentWidth, naturalPadding) }
        let style = NSScroller.preferredScrollerStyle
        if style == .legacy {
            let legacyWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            return (contentWidth + legacyWidth, contentWidth, naturalPadding)
        } else {
            let overlayWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
            let trailing = max(naturalPadding, overlayWidth + Self.overlayVisualGap)
            let width = contentWidth - naturalPadding + trailing
            return (width, width, trailing)
        }
    }

    // MARK: - Full Render

    private func performFullRender() {
        guard !isFullyRendered else { return }
        isFullyRendered = true

        let containerWidth = candidateContainer.frame.width
        let (_, _, initialTrailing) = scrollerGeometry(
            contentWidth: min(initialContentWidth, maxContentWidth), hasOverflow: true)
        for i in itemViews.count..<displayCount {
            let item = createItemView()
            item.absoluteIndex = i
            item.trailingInset = initialTrailing
            item.frame = NSRect(x: 0, y: yForRow(i), width: containerWidth, height: itemHeight)
            candidateContainer.addSubview(item)
            itemViews.append(item)
        }

        // Re-measure actual max width across all candidates
        var actualMaxWidth = initialContentWidth
        for i in 0..<displayCount {
            let measuredWidth = MacishCandidateItemView.measureWidth(candidates[i])
            actualMaxWidth = max(actualMaxWidth, measuredWidth)
        }

        let cappedWidth = min(actualMaxWidth, maxContentWidth)
        if cappedWidth > initialContentWidth {
            let (newWindowWidth, newItemWidth, newTrailing) = scrollerGeometry(
                contentWidth: cappedWidth, hasOverflow: true)

            candidateContainer.frame.size.width = newItemWidth
            for item in itemViews {
                item.trailingInset = newTrailing
                item.frame.size.width = newItemWidth
            }
            for sep in separatorViews where !sep.isHidden {
                sep.frame.size.width = newItemWidth
            }

            let newSize = NSSize(width: newWindowWidth, height: frame.height)
            let targetFrame = windowFrame(for: newSize, reposition: false)

            isAnimating = true
            animateFrame(to: targetFrame)
        }

        updateNumbering()
        updateItemHighlights()
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
            let candidate = candidates[i]
            if i >= numberedStart, i < numberedEnd {
                item.showIndex = true
                // pos >= indexLabels.count yields "" but keeps showIndex=true
                // (slot still reserved). Don't conflate with the scroll-out
                // case below where showIndex=false visually hides the slot.
                item.configure(label: label(for: i - anchorIndex), candidate: candidate)
            } else {
                item.configure(label: "", candidate: candidate)
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



    // MARK: - Selection

    override func updateItemHighlights() {
        super.updateItemHighlights()
        guard style == .tahoe else { return }
        let suspended = impl.suspendHighlight
        for (i, sep) in separatorViews.enumerated() where !sep.isHidden {
            // separator[i] sits between item[i] and item[i+1]
            let adjacentToSelection = i == selectedIndex - 1 || i == selectedIndex
            sep.alphaValue = (!suspended && adjacentToSelection) ? 0 : 1
        }
    }

    // MARK: - Commit

    override func commitCandidate(at index: Int) {
        guard isVisible else { return }
        guard index >= 0, index < pageSize else { return }
        let candidateIndex = anchorIndex + index
        guard candidateIndex < displayCount else { return }
        let chosen = candidates[candidateIndex]
        impl.candidateDelegate?.candidateConfirmed(chosen.text, raw: chosen)
    }

    // MARK: - Frame Animation

    override func frameAnimationDidFinish() {
        isAnimating = false
    }

    // MARK: - Scroller Style

    override func handleScrollerStyleChange() {
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        guard isVisible, !candidates.isEmpty else { return }
        buildCandidateLayout()
    }

    // MARK: - Item View Lifecycle

    private func removeAllItemViews() {
        for item in itemViews { item.removeFromSuperview() }
        itemViews.removeAll()
    }
}
