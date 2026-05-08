import Cocoa

class MacishVerticalPanel: MacishBasePanel {

    // MARK: - State

    private static let overlayVisualGap: CGFloat = 2

    /// Content width cap; independent of `pageSize`.
    private static let maxContentColumns = 6

    private var itemViews: [MacishCandidateItemView] = []
    private var anchorIndex = 0
    private var isFullyRendered = false
    // Suppresses scrollObserver-driven updateNumbering during build. Prevents
    // a stray bounds-change callback (triggered by container resize or
    // scroll(to: .zero)) from running while itemViews is in a transient state
    // and stamping anchorIndex to a value that makes the explicit final
    // updateNumbering early-out, leaving items unconfigured.
    private var isBuildingLayout = false
    private var initialContentWidth: CGFloat = 0
    private var maxContentWidth: CGFloat = 0
    private var naturalContentHeight: CGFloat = 0
    private var minVisibleRows = 0
    private var boundsObserver: (any NSObjectProtocol)?

    // Column alignment state (vertical mode only).
    // candidateColumnWidth: width to which all rows' candidate labels are
    //   padded so annotations align in a column. 0 = no alignment.
    // showAnnotations: when false, annotations are stripped at configure
    //   time (used when annotations don't have room or no candidate has them).
    private var candidateColumnWidth: CGFloat = 0
    private var showAnnotations: Bool = false

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
        isBuildingLayout = true
        defer { isBuildingLayout = false }
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

        let metrics = computeContentMetrics(candidates: candidates, fullScan: false)
        initialContentWidth = metrics.totalWidth
        candidateColumnWidth = metrics.columnWidth
        showAnnotations = metrics.showAnnotations
        maxContentWidth = baseColumnWidth * CGFloat(Self.maxContentColumns)

        let hasOverflow = displayCount > pageSize
        let cappedWidth = min(metrics.totalWidth, maxContentWidth)
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
            item.setCandidateColumnWidth(candidateColumnWidth)
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

    /// Linear pipeline:
    /// 1. Place index + candidate (column width = max candidate intrinsic, padded across rows)
    /// 2. Compute remaining = W - candidateBlock
    /// 3. Decide annotation visibility:
    ///    - no annotation -> hide, no column alignment
    ///    - has annotation but remaining < threshold -> hide (per "candidate truncated => no annotation" policy)
    ///    - has annotation and fits -> show, annotation truncates per row via `.byTruncatingTail`
    ///
    /// `fullScan = false` uses top-3 heuristic (called from buildCandidateLayout for fast initial paint).
    /// `fullScan = true` iterates all candidates (called from performFullRender to correct heuristic miss).
    private func computeContentMetrics(candidates: [Candidate], fullScan: Bool)
        -> (totalWidth: CGFloat, columnWidth: CGFloat, showAnnotations: Bool) {

        guard !candidates.isEmpty else {
            return (baseColumnWidth, 0, false)
        }
        let visible = Array(candidates.prefix(displayCount))

        let candidateTexts = topTexts(visible.map(\.text), fullScan: fullScan)
        let measuredMax = candidateTexts
            .map { MacishCandidateItemView.measureCandidateLabelWidth($0) }
            .max() ?? 0
        let maxCandidateWidth = max(measuredMax, MacishCandidateItemView.candidateFontSize)

        // Candidate.init normalized empty annotation to nil, so compactMap
        // is sufficient — no need to re-filter empty strings here.
        let annotated = visible.compactMap(\.annotation)
        let hasAnnotation = !annotated.isEmpty
        let maxAnnotationWidth: CGFloat = hasAnnotation
            ? topTexts(annotated, fullScan: fullScan)
                .map { MacishCandidateItemView.measureAnnotationLabelWidth($0) }
                .max() ?? 0
            : 0

        let constants = MacishCandidateItemView.leadingPadding
            + MacishCandidateItemView.indexWidth
            + MacishCandidateItemView.effectiveGap
            + MacishCandidateItemView.defaultTrailingPadding
        let candidateBlock = constants + maxCandidateWidth
        let remaining = baseColumnWidth * CGFloat(Self.maxContentColumns) - candidateBlock
        let threshold = MacishCandidateItemView.candidateAnnotationGap
            + MacishCandidateItemView.candidateFontSize
        let showAnnotations = hasAnnotation && remaining >= threshold

        let columnWidth = showAnnotations ? maxCandidateWidth : 0
        let naturalTotal = candidateBlock + (showAnnotations
            ? MacishCandidateItemView.candidateAnnotationGap + maxAnnotationWidth
            : 0)
        return (max(baseColumnWidth, naturalTotal), columnWidth, showAnnotations)
    }

    /// fullScan = true: all texts.
    /// fullScan = false: first page in full + any remaining items whose char
    /// count exceeds the first-page max (top-3 of those by length). The
    /// first-page-in-full part guarantees no truncation on what the user sees
    /// initially; the remainder feeds an early estimate for panel width but
    /// is not load-bearing — `performFullRender` rescans on scroll, where any
    /// missed wider candidate triggers a column / panel expand.
    private func topTexts(_ texts: [String], fullScan: Bool) -> [String] {
        guard !fullScan else { return texts }
        if texts.count <= pageSize { return texts }
        let firstPage = Array(texts.prefix(pageSize))
        let firstPageMaxLen = firstPage.map(\.count).max() ?? 0
        let restTop = texts[pageSize...]
            .filter { $0.count > firstPageMaxLen }
            .sorted { $0.count > $1.count }
            .prefix(3)
        return firstPage + restTop
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
            item.setCandidateColumnWidth(candidateColumnWidth)
            item.frame = NSRect(x: 0, y: yForRow(i), width: containerWidth, height: itemHeight)
            candidateContainer.addSubview(item)
            itemViews.append(item)
        }

        // Re-run metrics over the full candidate set. Heuristic top-3 may have
        // missed the actual widest (when char count doesn't track pixel
        // width — mixed-script lists). Both columnWidth and showAnnotations
        // can shift in either direction (e.g., maxAnnotation grows can push
        // remaining below threshold and flip showAnnotations to false).
        let metrics = computeContentMetrics(candidates: candidates, fullScan: true)
        let columnChanged = metrics.columnWidth != candidateColumnWidth
        let showChanged = metrics.showAnnotations != showAnnotations

        if columnChanged {
            candidateColumnWidth = metrics.columnWidth
            for item in itemViews {
                item.setCandidateColumnWidth(metrics.columnWidth)
            }
        }
        if showChanged {
            showAnnotations = metrics.showAnnotations
            // updateNumbering has an early-return guard on anchorIndex — force
            // it to actually rerun so existing items get reconfigured with
            // the new annotation-strip policy.
            anchorIndex = -1
        }

        let cappedWidth = min(metrics.totalWidth, maxContentWidth)
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
        guard !isBuildingLayout else { return }
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
            // Strip annotation when overflow guard disabled it (candidate
            // alone barely fits panel cap). Keeps row layout consistent
            // with no-annotation mode in those scenarios.
            let candidate = showAnnotations
                ? candidates[i]
                : Candidate(candidates[i].text, annotation: nil)
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
