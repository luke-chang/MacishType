import Cocoa

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: -

class SequoiaBasePanel: NSPanel, CandidateItemClickable {

    var impl: CandidateWindowImpl!

    static let separatorHeight: CGFloat = 1
    static let defaultCornerRadius: CGFloat = 6

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

    private(set) var backdrop: SequoiaBackdrop!
    var scrollView: NSScrollView!
    var candidateContainer: FlippedView!
    var rowHighlightView: SequoiaHighlightView!
    var separatorViews: [SequoiaSeparatorView] = []

    private enum WindowPlacement {
        case below, above, left, right
    }

    private var accentColorObserver: (any NSObjectProtocol)?
    private var scrollerStyleObserver: (any NSObjectProtocol)?
    private var previousPlacement: WindowPlacement?
    private var previousTopLeft: NSPoint = .zero
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
        backdrop = .make()
        self.contentView = backdrop.view

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        let contentArea = backdrop.contentArea
        contentArea.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
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
        let (topLeft, placement) = topLeftPoint(forWindowSize: frame.size, near: rect)
        let newOrigin = NSPoint(x: topLeft.x, y: topLeft.y - frame.height)
        let dx = newOrigin.x - frame.origin.x
        let dy = newOrigin.y - frame.origin.y
        let distanceSq = dx * dx + dy * dy

        let placementChanged = previousPlacement != nil && placement != previousPlacement

        let shouldAnimate: Bool
        if !isVisible {
            shouldAnimate = false
        } else if placementChanged {
            shouldAnimate = false
        } else {
            shouldAnimate = !isAnimating && distanceSq > 400
        }

        if shouldAnimate {
            // Snap to previous top-left before animating
            // (setContentSize keeps the origin, which shifts the top-left)
            if previousTopLeft != .zero {
                setFrameTopLeftPoint(previousTopLeft)
            }
            previousPlacement = placement
            previousTopLeft = topLeft
            isAnimating = true
            let newFrame = NSRect(origin: newOrigin, size: frame.size)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        } else if !isAnimating {
            previousPlacement = placement
            previousTopLeft = topLeft
            setFrameTopLeftPoint(topLeft)
        }
        orderFrontRegardless()
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

    private func topLeftPoint(forWindowSize windowSize: NSSize, near rect: NSRect) -> (point: NSPoint, placement: WindowPlacement) {
        let screenRect = screen(containing: rect)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 4.0
        var point = NSPoint(x: rect.minX, y: rect.minY - margin)
        var placement: WindowPlacement = .below

        if point.y - windowSize.height < screenRect.minY {
            let aboveY = rect.maxY + windowSize.height + margin
            if aboveY <= screenRect.maxY {
                point.y = aboveY
                placement = .above
            } else {
                // Can't fit below or above — position beside the composition area
                point.y = rect.maxY
                if point.y - windowSize.height < screenRect.minY {
                    point.y = screenRect.minY + windowSize.height
                }

                let leftX = impl.compositionStartX - windowSize.width - margin
                if leftX >= screenRect.minX {
                    point.x = leftX
                    placement = .left
                } else {
                    point.x = impl.compositionEndX + margin
                    placement = .right
                }
            }
        }

        if point.x + windowSize.width >= screenRect.maxX {
            point.x = screenRect.maxX - windowSize.width
        }
        if point.x < screenRect.minX {
            point.x = screenRect.minX
        }
        if point.y > screenRect.maxY {
            point.y = screenRect.maxY
        }

        return (point, placement)
    }

    func windowFrame(for contentSize: NSSize, reposition: Bool) -> NSRect {
        if reposition, lastShowNearRect != .zero {
            let (topLeft, _) = topLeftPoint(forWindowSize: contentSize, near: lastShowNearRect)
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

    // MARK: - Frame Animation

    private var frameDisplayLink: CADisplayLink?
    private var frameAnimStart: CFTimeInterval = 0
    private var frameAnimFrom: NSRect = .zero
    private var frameAnimTo: NSRect = .zero

    func animateFrame(to targetFrame: NSRect) {
        guard targetFrame != frame else { return }
        stopFrameAnimation()
        frameAnimFrom = frame
        frameAnimTo = targetFrame
        frameAnimStart = CACurrentMediaTime()
        let link = self.displayLink(target: self, selector: #selector(frameAnimTick))
        link.add(to: .main, forMode: .common)
        frameDisplayLink = link
    }

    func stopFrameAnimation() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
    }

    /// Evaluate the ease-in-out cubic bezier (0.42, 0, 0.58, 1) to match
    /// CAMediaTimingFunction(.easeInEaseOut) used by CABasicAnimation.
    private static func easeInOut(_ x: CGFloat) -> CGFloat {
        let x1: CGFloat = 0.42, x2: CGFloat = 0.58
        var t = x
        for _ in 0..<8 {
            let mt = 1 - t
            let xErr = 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t * t * t - x
            if abs(xErr) < 1e-7 { break }
            let dx = 3 * mt * mt * x1 + 6 * mt * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(dx) < 1e-7 { break }
            t -= xErr / dx
        }
        return 3 * t * t - 2 * t * t * t
    }

    @objc private func frameAnimTick() {
        let elapsed = CACurrentMediaTime() - frameAnimStart
        let progress = min(elapsed / animationDuration, 1.0)
        let t = Self.easeInOut(progress)

        let from = frameAnimFrom, to = frameAnimTo
        let currentFrame = NSRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * t,
            y: from.origin.y + (to.origin.y - from.origin.y) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
        setFrame(currentFrame, display: true)
        frameAnimationDidTick(t: t)

        if progress >= 1.0 {
            stopFrameAnimation()
            frameAnimationDidFinish()
        }
    }

    func frameAnimationDidTick(t: CGFloat) {}
    func frameAnimationDidFinish() {}

    // MARK: - Hide

    func hide() {
        stopFrameAnimation()
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
        baseColumnWidth = SequoiaCandidateItemView.baseWidth
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
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        backdrop.applyUniformCorners(size: size, radius: Self.defaultCornerRadius)
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

// MARK: - SequoiaBackdrop

/// Type-erased wrapper for the candidate window background view.
/// Encapsulates the version-branching between NSVisualEffectView (macOS 14+)
/// and NSGlassEffectView (macOS 26+) so callers never see `if #available`.
struct SequoiaBackdrop {

    let view: NSView
    let contentArea: NSView

    fileprivate let uniformCorners: (NSSize, CGFloat) -> Void
    fileprivate let asymmetricCorners: (NSSize, CGFloat, CGFloat) -> Void

    func applyUniformCorners(size: NSSize, radius: CGFloat) {
        uniformCorners(size, radius)
    }

    func applyAsymmetricCorners(size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat) {
        asymmetricCorners(size, leftRadius, rightRadius)
    }
}

extension SequoiaBackdrop {

    static func make() -> SequoiaBackdrop {
        if #available(macOS 26, *) {
            return makeGlass()
        }
        return makeVibrancy()
    }

    private static func makeVibrancy() -> SequoiaBackdrop {
        let v = VibrancyBackgroundView()
        return SequoiaBackdrop(
            view: v,
            contentArea: v,
            uniformCorners: { v.applyUniformCorners(size: $0, radius: $1) },
            asymmetricCorners: { v.applyAsymmetricCorners(size: $0, leftRadius: $1, rightRadius: $2) }
        )
    }

    @available(macOS 26, *)
    private static func makeGlass() -> SequoiaBackdrop {
        let v = GlassBackgroundView()
        return SequoiaBackdrop(
            view: v,
            contentArea: v.container,
            uniformCorners: { v.applyUniformCorners(size: $0, radius: $1) },
            asymmetricCorners: { v.applyAsymmetricCorners(size: $0, leftRadius: $1, rightRadius: $2) }
        )
    }
}

// MARK: - Corner Path

private func asymmetricCornerPath(
    size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat
) -> CGPath {
    let rect = CGRect(origin: .zero, size: size)
    let lr = min(leftRadius, rect.height / 2)
    let rr = min(rightRadius, rect.height / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: lr, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - rr, y: rect.maxY))
    path.addArc(center: CGPoint(x: rect.maxX - rr, y: rect.maxY - rr),
                 radius: rr, startAngle: .pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: rect.maxX, y: rr))
    path.addArc(center: CGPoint(x: rect.maxX - rr, y: rr),
                 radius: rr, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: lr, y: 0))
    path.addArc(center: CGPoint(x: lr, y: lr),
                 radius: lr, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
    path.addLine(to: CGPoint(x: 0, y: rect.maxY - lr))
    path.addArc(center: CGPoint(x: lr, y: rect.maxY - lr),
                 radius: lr, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    path.closeSubpath()
    return path
}

// MARK: - NSVisualEffectView (macOS 14+)

private class VibrancyBackgroundView: NSVisualEffectView {

    private var cachedSize: NSSize = .zero
    private var cachedLeft: CGFloat = -1
    private var cachedRight: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyUniformCorners(size: NSSize, radius: CGFloat) {
        applyAsymmetricCorners(size: size, leftRadius: radius, rightRadius: radius)
    }

    func applyAsymmetricCorners(size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        if size == cachedSize, leftRadius == cachedLeft, rightRadius == cachedRight { return }
        cachedSize = size
        cachedLeft = leftRadius
        cachedRight = rightRadius
        let cgPath = asymmetricCornerPath(size: size, leftRadius: leftRadius, rightRadius: rightRadius)
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(cgPath: cgPath).fill()
            return true
        }
    }
}

// MARK: - NSGlassEffectView (macOS 26+)

@available(macOS 26, *)
private class GlassBackgroundView: NSGlassEffectView {

    fileprivate let container = NSView()
    private var maskLayer: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .regular
        contentView = container
        // Prevent small-surface light/dark color scheme flipping (private API).
        if responds(to: Selector(("_adaptiveAppearance"))) {
            setValue(1, forKey: "_adaptiveAppearance")
        }
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyUniformCorners(size: NSSize, radius: CGFloat) {
        layer?.mask = nil
        maskLayer = nil
        cornerRadius = radius
    }

    func applyAsymmetricCorners(size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        cornerRadius = 0
        let shape = maskLayer ?? {
            let s = CAShapeLayer()
            layer?.mask = s
            maskLayer = s
            return s
        }()
        shape.frame = CGRect(origin: .zero, size: size)
        shape.path = asymmetricCornerPath(size: size, leftRadius: leftRadius, rightRadius: rightRadius)
    }
}
