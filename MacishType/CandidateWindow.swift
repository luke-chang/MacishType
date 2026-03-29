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
    private static let padding: CGFloat = 6

    let indexLabel = NSTextField(labelWithString: "")
    let candidateLabel = NSTextField(labelWithString: "")
    var absoluteIndex: Int = 0

    var isHighlighted: Bool = false {
        didSet { updateAppearance() }
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

        candidateLabel.font = .systemFont(ofSize: Self.candidateFontSize)
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indexLabel)
        addSubview(candidateLabel)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            candidateLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: Self.padding),
            candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            candidateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            candidateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize + Self.padding * 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int, candidate: String) {
        indexLabel.stringValue = "\(index)"
        candidateLabel.stringValue = candidate
    }

    override func mouseUp(with event: NSEvent) {
        guard (window as? CandidateWindow)?.didDrag != true else { return }
        (window as? CandidateWindow)?.itemClicked(at: absoluteIndex, doubleClick: event.clickCount >= 2)
    }

    private func updateAppearance() {
        if isHighlighted {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
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

    private enum DisplayMode {
        case collapsed
        case expanded
    }

    private let indexBase = 1
    private let pageSize = 9
    private let maxPoolSize = 100
    private let maxDisplayCandidates = 200
    private var candidates: [String] = []
    private var selectedIndex: Int = 0
    private var displayMode: DisplayMode = .collapsed
    private var lastShowNearRect: NSRect = .zero
    private var isAnimating = false
    private var expandedRowsBuilt = false
    private(set) var didDrag = false

    private var outerStackView: NSStackView!
    private var allItemViews: [CandidateItemView] = []
    private var itemViewPool: [CandidateItemView] = []
    private var rowContainers: [RowContainerView] = []
    private var chevronImageView: ClickableImageView!
    private var chevronSeparator: NSBox!
    private var chevronSeparatorHeight: NSLayoutConstraint?
    weak var candidateDelegate: CandidateWindowDelegate?

    // MARK: - Init

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        setupUI()
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
            guard let self, !self.isAnimating,
                  self.displayMode == .collapsed, self.candidates.count > self.pageSize
            else { return }
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

    // MARK: - Public API

    func updateCandidates(_ candidates: [String]) {
        self.candidates = candidates
        self.selectedIndex = 0
        self.displayMode = .collapsed
        self.isAnimating = false
        rebuildLayout(animated: false)
    }

    func handleNavigation(direction: NavigationDirection, wrapping: Bool = false) {
        guard !candidates.isEmpty, !isAnimating else { return }

        let target = navigationTarget(direction: direction)
            ?? (wrapping ? wrappingTarget(direction: direction) : nil)

        guard let target else {
            if displayMode == .expanded, Self.collapseDirections.contains(direction) {
                collapseWindow(animated: true)
            }
            return
        }

        if displayMode == .collapsed, target >= pageSize {
            selectedIndex = target
            expandWindow(animated: true)
        } else {
            moveSelection(to: target)
        }
    }

    func commitSelectedCandidate() {
        guard isVisible, selectedIndex >= 0, selectedIndex < displayCount else { return }
        candidateDelegate?.candidateSelected(candidates[selectedIndex])
    }

    func commitCandidateForDigit(_ digit: Int) {
        guard isVisible else { return }
        let index = selectedIndex / pageSize * pageSize + digit - indexBase
        guard index >= 0, index < displayCount else { return }
        candidateDelegate?.candidateSelected(candidates[index])
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
                context.duration = 0.15
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

    private static let collapseDirections: Set<NavigationDirection> = [.left, .up, .home]

    private func wrappingTarget(direction: NavigationDirection) -> Int? {
        let currentCol = selectedIndex % pageSize
        let totalRows = (displayCount + pageSize - 1) / pageSize
        switch direction {
        case .right where selectedIndex >= displayCount - 1:
            return 0
        case .left where selectedIndex <= 0:
            return displayCount - 1
        case .down where selectedIndex / pageSize >= totalRows - 1:
            return min(currentCol, displayCount - 1)
        case .up where selectedIndex / pageSize <= 0:
            return min((totalRows - 1) * pageSize + currentCol, displayCount - 1)
        default:
            return nil
        }
    }

    private func navigationTarget(direction: NavigationDirection) -> Int? {
        let currentRow = selectedIndex / pageSize
        let currentCol = selectedIndex % pageSize
        let totalRows = (displayCount + pageSize - 1) / pageSize

        switch direction {
        case .right:
            return selectedIndex + 1 < displayCount ? selectedIndex + 1 : nil
        case .left:
            return selectedIndex > 0 ? selectedIndex - 1 : nil
        case .down:
            guard currentRow < totalRows - 1 else { return nil }
            return min((currentRow + 1) * pageSize + currentCol, displayCount - 1)
        case .up:
            guard currentRow > 0 else { return nil }
            return (currentRow - 1) * pageSize + currentCol
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
        if !expandedRowsBuilt {
            buildExpandedRows()
        }
        applyDisplayMode()
        animateToFittingSize(repositionAfter: true)
    }

    private func buildExpandedRows() {
        let totalRows = (displayCount + pageSize - 1) / pageSize
        let selectedRow = selectedIndex / pageSize

        for row in 1..<totalRows {
            let startIndex = row * pageSize
            let count = min(pageSize, displayCount - startIndex)
            let isSelectedRow = row == selectedRow
            let rowContainer = makeRow(
                startIndex: startIndex,
                count: count,
                showIndices: isSelectedRow,
                highlighted: isSelectedRow
            )
            outerStackView.addArrangedSubview(rowContainer)
        }

        if rowContainers.count > 1 {
            for i in 1..<rowContainers.count {
                rowContainers[i].widthAnchor.constraint(
                    equalTo: rowContainers[0].widthAnchor
                ).isActive = true
            }
        }

        expandedRowsBuilt = true
    }

    private func collapseWindow(animated: Bool) {
        displayMode = .collapsed
        applyDisplayMode()
        animateToFittingSize(repositionAfter: true)
    }

    private func applyDisplayMode() {
        let isCollapsed = displayMode == .collapsed

        chevronImageView.isHidden = !isCollapsed
        chevronSeparator.isHidden = !isCollapsed

        for (rowIndex, container) in rowContainers.enumerated() where rowIndex > 0 {
            container.isHidden = isCollapsed
        }

        if isCollapsed {
            for (rowIndex, container) in rowContainers.enumerated() {
                container.isRowHighlighted = false
                let startIndex = rowIndex * pageSize
                let endIndex = min(startIndex + pageSize, displayCount)
                for i in startIndex..<endIndex {
                    allItemViews[i].showIndex = (rowIndex == 0)
                }
            }
        } else {
            updateRowHighlightsAndIndices()
        }

        updateSelection()
    }

    // MARK: - View Pool

    private func dequeueItemView() -> CandidateItemView {
        if let item = itemViewPool.popLast() {
            item.isHighlighted = false
            item.showIndex = true
            return item
        }
        return CandidateItemView()
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

        guard !candidates.isEmpty else { return }

        let count = min(pageSize, displayCount)
        let firstRow = makeRow(
            startIndex: 0, count: count, showIndices: true, highlighted: false)

        if candidates.count > pageSize {
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

        expandedRowsBuilt = false
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

    private func makeRow(
        startIndex: Int, count: Int, showIndices: Bool, highlighted: Bool
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

        for i in 0..<count {
            let absoluteIndex = startIndex + i
            let item = dequeueItemView()
            item.absoluteIndex = absoluteIndex
            item.configure(index: i % pageSize + indexBase, candidate: candidates[absoluteIndex])
            item.showIndex = showIndices
            stackView.addArrangedSubview(item)
            allItemViews.append(item)
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
        let oldRow = selectedIndex / pageSize
        selectedIndex = newIndex
        updateSelection()
        if displayMode == .expanded && oldRow != selectedIndex / pageSize {
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
        let selectedRow = selectedIndex / pageSize

        for (rowIndex, container) in rowContainers.enumerated() {
            let isSelected = rowIndex == selectedRow
            container.isRowHighlighted = isSelected

            let startIndex = rowIndex * pageSize
            let endIndex = min(startIndex + pageSize, displayCount)
            for i in startIndex..<endIndex {
                allItemViews[i].showIndex = isSelected
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
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
        })
    }
}
