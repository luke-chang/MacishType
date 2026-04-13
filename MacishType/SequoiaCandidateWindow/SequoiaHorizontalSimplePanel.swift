import Cocoa

class SequoiaHorizontalSimplePanel: SequoiaHorizontalBasePanel {

    private struct GridItem {
        let candidateIndex: Int
        let measuredWidth: CGFloat
    }

    private enum PageDirection { case forward, backward }

    // MARK: - State

    private var pages: [[GridItem]] = []
    private var currentPage: Int = 0
    private var nextCandidateOffset: Int = 0
    private var remainingPagesBuilt = false

    private var currentPageItems: [GridItem] { pages[currentPage] }
    private var hasMultiplePages: Bool { pages.count > 1 || nextCandidateOffset < displayCount }
    private var hasNextPage: Bool { remainingPagesBuilt ? currentPage < pages.count - 1 : nextCandidateOffset < displayCount }

    private var pageItemViews: [[SequoiaCandidateItemView]] = []
    private var pageArrowView: SequoiaPageArrowView!

    override var allItemViews: [SequoiaCandidateItemView] { pageItemViews.flatMap { $0 } }

    // MARK: - Init

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        scrollView.hasVerticalScroller = false

        pageArrowView = SequoiaPageArrowView()
        pageArrowView.onPageUp = { [weak self] in
            self?.handleNavigation(direction: .pageBackward, wrapping: false)
        }
        pageArrowView.onPageDown = { [weak self] in
            self?.handleNavigation(direction: .pageForward, wrapping: false)
        }
        candidateContainer.addSubview(pageArrowView)
    }

    // MARK: - Configuration

    override func updateFontSize(_ fontSize: CGFloat) {
        super.updateFontSize(fontSize)
        pageArrowView.updateFontSize(fontSize)
    }

    override func apply(_ configuration: CandidateWindowConfiguration) {
        super.apply(configuration)
        if isVisible, !candidates.isEmpty {
            buildCandidateLayout()
            restoreSelection(to: impl?.selectedIndex ?? 0)
        }
    }

    // MARK: - Grid Computation

    private func packPage(startingAt offset: Int) -> (items: [GridItem], nextOffset: Int) {
        let maxWidth = baseColumnWidth * CGFloat(pageSize)
        var items: [GridItem] = []
        var usedWidth: CGFloat = 0
        var offset = offset
        for _ in 0..<pageSize {
            guard offset < displayCount else { break }
            let raw = SequoiaCandidateItemView.measureWidth(index: items.count + indexBase, candidate: candidates[offset])
            let w = max(baseColumnWidth, min(raw, maxWidth))
            if usedWidth + w > maxWidth, !items.isEmpty { break }
            items.append(GridItem(candidateIndex: offset, measuredWidth: w))
            usedWidth += w
            offset += 1
        }
        return (items, offset)
    }

    private func computeFirstPage() -> [GridItem] {
        let (items, nextOffset) = packPage(startingAt: 0)
        nextCandidateOffset = nextOffset
        return items
    }

    private func computeRemainingPages() {
        var offset = nextCandidateOffset
        while offset < displayCount {
            let (items, nextOffset) = packPage(startingAt: offset)
            pages.append(items)
            offset = nextOffset
        }
    }

    // MARK: - Layout

    override func buildCandidateLayout() {
        currentPage = 0
        pages = []
        nextCandidateOffset = 0
        remainingPagesBuilt = false
        for views in pageItemViews { views.forEach { $0.removeFromSuperview() } }
        pageItemViews = []

        guard !candidates.isEmpty else {
            setContentSize(.zero)
            return
        }

        computeBaseMetrics()
        pages = [computeFirstPage()]

        var page0Views: [SequoiaCandidateItemView] = []
        for (pos, gridItem) in currentPageItems.enumerated() {
            let item = createItemView()
            item.absoluteIndex = gridItem.candidateIndex
            item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
            candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
            page0Views.append(item)
        }
        pageItemViews = [page0Views]

        updateItemHighlights()
        updatePagingArrowStates()
        let contentSize = layoutItems()
        setContentSize(contentSize)
        updateMaskImage()

        if isVisible, lastShowNearRect != .zero {
            show(near: lastShowNearRect)
        }
    }

    @discardableResult
    private func layoutItems(previousPage: Int? = nil) -> NSSize {
        let row0Y = yForRow(0)
        var currentPageWidth: CGFloat = 0
        let currentViews = pageItemViews[currentPage]

        if let previousPage, previousPage < pageItemViews.count {
            for item in pageItemViews[previousPage] { item.isHidden = true }
        }
        for item in currentViews { item.isHidden = false }

        for (i, item) in currentViews.enumerated() {
            let w = max(baseColumnWidth, currentPageItems[i].measuredWidth)
            item.frame = NSRect(x: currentPageWidth, y: row0Y, width: w, height: itemHeight)
            currentPageWidth += w
        }

        let chevronWidth = pageArrowView.intrinsicContentSize.width
        if hasMultiplePages {
            pageArrowView.isHidden = false
            let contentWidth = max(currentPageWidth, baseColumnWidth * CGFloat(pageSize))
            pageArrowView.frame = NSRect(x: contentWidth, y: row0Y,
                                         width: chevronWidth, height: itemHeight)
            let windowWidth = contentWidth + chevronWidth
            candidateContainer.frame.size = NSSize(width: windowWidth, height: itemHeight)
            return NSSize(width: windowWidth, height: itemHeight)
        } else {
            pageArrowView.isHidden = true
            candidateContainer.frame.size = NSSize(width: currentPageWidth, height: itemHeight)
            return NSSize(width: currentPageWidth, height: itemHeight)
        }
    }

    // MARK: - Paging

    private func buildRemainingPages() {
        guard !remainingPagesBuilt else { return }
        computeRemainingPages()
        for pageIdx in 1..<pages.count {
            var views: [SequoiaCandidateItemView] = []
            for (pos, gridItem) in pages[pageIdx].enumerated() {
                let item = createItemView()
                item.absoluteIndex = gridItem.candidateIndex
                item.configure(index: pos + indexBase, candidate: candidates[gridItem.candidateIndex])
                item.isHidden = true
                candidateContainer.addSubview(item, positioned: .above, relativeTo: rowHighlightView)
                views.append(item)
            }
            pageItemViews.append(views)
        }
        remainingPagesBuilt = true
    }

    private func switchToPage(_ page: Int) {
        guard page != currentPage else { return }
        buildRemainingPages()
        guard page >= 0, page < pages.count else { return }
        let oldPage = currentPage
        currentPage = page
        updatePagingArrowStates()
        layoutItems(previousPage: oldPage)
    }

    private func goToPage(_ page: Int, preserving direction: PageDirection? = nil) {
        var xStart: CGFloat = 0
        var xEnd: CGFloat = 0
        if direction != nil {
            for item in currentPageItems {
                let w = max(baseColumnWidth, item.measuredWidth)
                if item.candidateIndex == selectedIndex {
                    xStart = xEnd
                    xEnd += w
                    break
                }
                xEnd += w
            }
        }
        switchToPage(page)
        if let direction {
            moveSelection(to: findOverlappingItem(xStart: xStart, xEnd: xEnd, direction: direction)
                          ?? currentPageItems.last?.candidateIndex ?? 0)
        } else {
            moveSelection(to: currentPageItems.first?.candidateIndex ?? 0)
        }
    }

    private func findOverlappingItem(xStart: CGFloat, xEnd: CGFloat, direction: PageDirection) -> Int? {
        var x: CGFloat = 0
        for (i, item) in currentPageItems.enumerated() {
            let w = max(baseColumnWidth, item.measuredWidth)
            let itemEnd = x + w
            if x < xEnd, itemEnd > xStart {
                if direction == .backward, x < xStart, i + 1 < currentPageItems.count {
                    let nextX = itemEnd
                    if nextX < xEnd {
                        return currentPageItems[i + 1].candidateIndex
                    }
                }
                return item.candidateIndex
            }
            x = itemEnd
        }
        return nil
    }

    private func updatePagingArrowStates() {
        pageArrowView.canPageUp = currentPage > 0
        pageArrowView.canPageDown = remainingPagesBuilt
            ? currentPage < pages.count - 1
            : nextCandidateOffset < displayCount
    }

    // MARK: - Navigation

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        guard !candidates.isEmpty else { return }
        switch direction {
        case .left, .right, .itemBackward, .itemForward:
            navigateHorizontal(direction: direction, wrapping: wrapping)
        case .down, .pageDown, .pageForward:
            if hasNextPage {
                goToPage(currentPage + 1, preserving: .forward)
            } else if wrapping {
                goToPage(0, preserving: .forward)
            }
        case .up, .pageUp, .pageBackward:
            if currentPage > 0 {
                goToPage(currentPage - 1, preserving: .backward)
            } else if wrapping {
                buildRemainingPages()
                goToPage(pages.count - 1, preserving: .backward)
            }
        case .home:
            if let first = currentPageItems.first?.candidateIndex, selectedIndex != first {
                moveSelection(to: first)
            }
        case .end:
            if let last = currentPageItems.last?.candidateIndex, selectedIndex != last {
                moveSelection(to: last)
            }
        }
    }

    private func navigateHorizontal(direction: NavigationDirection, wrapping: Bool) {
        let isForward = direction == .right || direction == .itemForward
        if isForward {
            if let last = currentPageItems.last?.candidateIndex, selectedIndex < last {
                moveSelection(to: selectedIndex + 1)
            } else if hasNextPage {
                goToPage(currentPage + 1)
            } else if wrapping {
                goToPage(0)
            }
        } else {
            if let first = currentPageItems.first?.candidateIndex, selectedIndex > first {
                moveSelection(to: selectedIndex - 1)
            } else if currentPage > 0 {
                switchToPage(currentPage - 1)
                moveSelection(to: currentPageItems.last?.candidateIndex ?? 0)
            } else if wrapping {
                buildRemainingPages()
                switchToPage(pages.count - 1)
                moveSelection(to: currentPageItems.last?.candidateIndex ?? 0)
            }
        }
    }

    // MARK: - Selection & Highlights

    override func updateItemHighlights() {
        guard currentPage < pageItemViews.count else { return }
        for item in pageItemViews[currentPage] {
            item.isHighlighted = item.absoluteIndex == selectedIndex
        }
    }

    override func restoreSelection(to index: Int) {
        let target = min(index, max(displayCount - 1, 0))
        if let pageIdx = pages.firstIndex(where: { $0.contains { $0.candidateIndex == target } }),
           pageIdx != currentPage {
            switchToPage(pageIdx)
        }
        moveSelection(to: target)
    }

    override func ensureSelectionVisible() {
        if let pageIdx = pages.firstIndex(where: { $0.contains { $0.candidateIndex == selectedIndex } }),
           pageIdx != currentPage {
            switchToPage(pageIdx)
        }
    }

    // MARK: - Commit

    override func commitCandidateForDigit(_ digit: Int) {
        guard isVisible else { return }
        let itemOffset = digit - indexBase
        guard itemOffset >= 0, itemOffset < currentPageItems.count else { return }
        let candidateIndex = currentPageItems[itemOffset].candidateIndex
        guard candidateIndex < candidates.count else { return }
        impl.candidateDelegate?.candidateConfirmed(candidates[candidateIndex])
    }

    // MARK: - Mask

    override func updateMaskImage() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        if hasMultiplePages {
            applyPillCorners(size: size)
        } else {
            applyUniformCorners()
        }
    }
}
