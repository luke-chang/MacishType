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
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: -

class SequoiaBasePanel: NSPanel, CandidateItemClickable {

    var impl: CandidateWindowImpl!

    static let separatorHeight: CGFloat = 1
    static let defaultCornerRadius: CGFloat = 6
    static let uniformMask = NSImage.uniformCornerMask(radius: defaultCornerRadius)

    private(set) var highlightColor: NSColor = .selectedContentBackgroundColor
    private(set) var didDrag = false
    var animationDuration: TimeInterval = 0.183
    var candidates: [String] { impl.candidates }
    var selectedIndex: Int { impl.selectedIndex }
    var indexBase = 1
    var pageSize = 9
    let maxDisplayCandidates = 200
    var isAnimating = false
    private(set) var itemHeight: CGFloat = 0
    private(set) var baseColumnWidth: CGFloat = 0

    // MARK: - View Hierarchy

    var visualEffectView: NSVisualEffectView!
    var scrollView: NSScrollView!
    var candidateContainer: FlippedView!
    var rowHighlightView: SequoiaHighlightView!
    var separatorViews: [SequoiaSeparatorView] = []

    private var accentColorObserver: (any NSObjectProtocol)?
    private var scrollerStyleObserver: (any NSObjectProtocol)?
    private var dragOffset: NSPoint = .zero
    private var dragStartScreen: NSPoint = .zero

    // MARK: - Computed

    var displayCount: Int { min(candidates.count, maxDisplayCandidates) }
    var lastShowNearRect: NSRect { impl.lastShowNearRect }

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

    @MainActor deinit {
        if let observer = accentColorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = scrollerStyleObserver {
            NotificationCenter.default.removeObserver(observer)
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

        rowHighlightView = SequoiaHighlightView()
        candidateContainer.addSubview(rowHighlightView)
    }

    // MARK: - Theme / Highlight Color

    func updateHighlightColor() {
        if ThemeManager.shared.isMulticolor,
           let bundleID = impl.bundleIdentifier,
           let color = ThemeManager.shared.bundleAccentColor(bundleIdentifier: bundleID) {
            highlightColor = color
        } else {
            highlightColor = .selectedContentBackgroundColor
        }
        for item in allItemViews { item.highlightColor = highlightColor }
    }

    func bundleIdentifierDidChange() {
        updateHighlightColor()
    }

    // MARK: - Positioning

    func show(near rect: NSRect) {
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

    func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(rect.origin) }
            ?? NSScreen.screens.max(by: { a, b in
                let aRect = a.frame.intersection(rect)
                let bRect = b.frame.intersection(rect)
                let aArea = aRect.isNull ? 0 : aRect.width * aRect.height
                let bArea = bRect.isNull ? 0 : bRect.width * bRect.height
                return aArea < bArea
            })
    }

    func topLeftPoint(forWindowSize windowSize: NSSize, near rect: NSRect) -> NSPoint {
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

    func windowFrame(for contentSize: NSSize, reposition: Bool) -> NSRect {
        if reposition, lastShowNearRect != .zero {
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
            if lastShowNearRect != .zero {
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

    // MARK: - Hide

    func hide() {
        orderOut(nil)
    }

    // MARK: - Dragging

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

    // MARK: - Commit

    func itemClicked(at index: Int, doubleClick: Bool) {
        guard !isAnimating else { return }
        if doubleClick {
            impl.candidateDelegate?.candidateConfirmed(candidates[index])
        } else {
            moveSelection(to: index)
        }
    }

    func commitSelectedCandidate() {
        guard isVisible, selectedIndex >= 0, selectedIndex < displayCount else { return }
        impl.candidateDelegate?.candidateConfirmed(candidates[selectedIndex])
    }

    func updateCandidates(_ candidates: [String]) {
        impl.candidates = candidates
        impl.selectedIndex = 0
        buildCandidateLayout()
        impl.notifySelectionChanged()
    }

    // MARK: - Selection

    func moveSelection(to newIndex: Int) {
        impl.selectedIndex = newIndex
        updateItemHighlights()
        impl.notifySelectionChanged()
    }

    func updateItemHighlights() {
        for item in allItemViews {
            item.isHighlighted = item.absoluteIndex == selectedIndex
        }
    }

    func restoreSelection(to index: Int) {
        moveSelection(to: min(index, max(displayCount - 1, 0)))
        ensureSelectionVisible()
    }

    // MARK: - Helpers

    func computeBaseMetrics() {
        baseColumnWidth = SequoiaCandidateItemView.measureWidth(index: indexBase, candidate: "\u{5B57}")
        itemHeight = SequoiaCandidateItemView.itemHeight
    }

    func yForRow(_ rowIndex: Int) -> CGFloat {
        CGFloat(rowIndex) * (itemHeight + Self.separatorHeight)
    }

    func createItemView() -> SequoiaCandidateItemView {
        let item = SequoiaCandidateItemView()
        item.highlightColor = highlightColor
        return item
    }

    func ensureSeparators(count: Int, width: CGFloat) {
        while separatorViews.count < count {
            let sep = SequoiaSeparatorView()
            candidateContainer.addSubview(sep, positioned: .above, relativeTo: rowHighlightView)
            separatorViews.append(sep)
        }
        for i in 0..<count {
            separatorViews[i].frame = NSRect(
                x: 0, y: yForRow(i) + itemHeight,
                width: width, height: Self.separatorHeight)
            separatorViews[i].isHidden = false
            separatorViews[i].needsDisplay = true
        }
        for i in count..<separatorViews.count {
            separatorViews[i].isHidden = true
        }
    }

    func updateMaskImage() {
        visualEffectView.maskImage = Self.uniformMask
    }

    // MARK: - Subclass Override Points

    var allItemViews: [SequoiaCandidateItemView] { [] }
    func updateFontSize(_ fontSize: CGFloat) {
        SequoiaCandidateItemView.updateFontSize(fontSize)
    }
    func apply(_ configuration: CandidateWindowConfiguration) {
        if let fontSize = configuration.fontSize {
            updateFontSize(fontSize)
        }
        indexBase = configuration.indexBase
        pageSize = configuration.pageSize
        animationDuration = configuration.animationDuration
    }
    func buildCandidateLayout() {}
    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitCandidateForDigit(_ digit: Int) {}
    func ensureSelectionVisible() {}
    func handleScrollerStyleChange() {}
}
