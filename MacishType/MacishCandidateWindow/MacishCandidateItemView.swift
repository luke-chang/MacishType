import Cocoa

class MacishCandidateItemView: NSView {
    static private(set) var candidateFontSize: CGFloat = 16
    private static var indexFontSize: CGFloat = 8
    private static var annotationFontSize: CGFloat = 12
    static private(set) var indexWidth: CGFloat = computeIndexWidth(labels: "1234567890", fontSize: 8)
    static private(set) var leadingPadding: CGFloat = 4
    private static var indexCandidateGap: CGFloat = 6
    static private(set) var candidateAnnotationGap: CGFloat = 11
    static private(set) var defaultTrailingPadding: CGFloat = 9
    private static var verticalPadding: CGFloat = 12

    // labelMax cache keyed by labels; wipes on fontSize change. Capped
    // to protect against preview-app TextField input growing it.
    private static let indexWidthCacheCap = 32
    private static var indexWidthCache: [String: CGFloat] = [:]
    private static var cachedFontSize: CGFloat = 0

    // Engine default; doubles as the floor for per-update overrides.
    // Empty string allowed (engine wants no index column).
    private static var fallbackLabels: String = "1234567890"

    // Cached floor (max(width("0"), fallbackLabels max)); -1 = unset.
    private static var cachedFloor: CGFloat = -1

    private static func computeIndexWidth(labels: String, fontSize: CGFloat) -> CGFloat {
        let effective = labels.allSatisfy(\.isWhitespace) ? fallbackLabels : labels

        if cachedFontSize != fontSize {
            indexWidthCache.removeAll()
            cachedFontSize = fontSize
            cachedFloor = -1
        }

        guard !effective.isEmpty else { return 0 }

        let font = NSFont.systemFont(ofSize: fontSize)
        func charWidth(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }

        // width("0") = NSTextField render-threshold safety for narrow chars;
        // engine default = per-update override visual stability.
        if cachedFloor < 0 {
            let engineDefaultMax = fallbackLabels.map { charWidth(String($0)) }.max() ?? 0
            cachedFloor = max(charWidth("0"), engineDefaultMax)
        }

        let labelMax: CGFloat
        if let cached = indexWidthCache[effective] {
            labelMax = cached
        } else {
            labelMax = effective.map { charWidth(String($0)) }.max() ?? 0
            if indexWidthCache.count >= indexWidthCacheCap { indexWidthCache.removeAll() }
            indexWidthCache[effective] = labelMax
        }
        return max(cachedFloor, labelMax)
    }

    /// Does NOT touch indexWidth — caller must pair with `updateIndexLabels`
    /// so width reflects the current labels at the new size.
    static func updateFontSize(_ newSize: CGFloat) {
        let size = max(newSize, 8)
        guard size != candidateFontSize else { return }
        let scale = size / 16
        candidateFontSize = size
        indexFontSize = round(size / 2)
        annotationFontSize = round(size * 0.75)
        leadingPadding = round(4 * scale)
        indexCandidateGap = round(6 * scale)
        candidateAnnotationGap = round(11 * scale)
        defaultTrailingPadding = round(9 * scale)
        verticalPadding = round(12 * scale)
        templateView = nil
    }

    static func setFallbackLabels(_ labels: String) {
        guard fallbackLabels != labels else { return }
        fallbackLabels = labels
        cachedFloor = -1
    }

    static func updateIndexLabels(_ labels: String) {
        let newWidth = computeIndexWidth(labels: labels, fontSize: indexFontSize)
        guard newWidth != indexWidth else { return }
        indexWidth = newWidth
        templateView = nil
    }

    let style: CandidateWindow.Style
    private var contentInset: CGFloat { style == .tahoe ? 2 : 0 }
    private var highlightView: NSView?

    let indexLabel = NSTextField(labelWithString: "")
    let candidateLabel = NSTextField(labelWithString: "")
    let annotationLabel = NSTextField(labelWithString: "")
    var absoluteIndex: Int = 0

    var isHighlighted: Bool = false {
        didSet { updateAppearance() }
    }

    var highlightColor: NSColor = .selectedContentBackgroundColor {
        didSet {
            guard highlightColor != oldValue else { return }
            updateAppearance()
        }
    }

    var showIndex: Bool = true {
        didSet {
            guard showIndex != oldValue else { return }
            indexLabel.alphaValue = showIndex ? 1 : 0
        }
    }

    var trailingInset: CGFloat = defaultTrailingPadding {
        didSet {
            guard trailingInset != oldValue else { return }
            trailingConstraint.constant = -trailingInset
        }
    }

    private var trailingConstraint: NSLayoutConstraint!
    private var indexLabelWidthConstraint: NSLayoutConstraint!
    private var indexCandidateGapConstraint: NSLayoutConstraint!
    private var candidateAnnotationGapConstraint: NSLayoutConstraint!
    /// candidate label minimum width. constant = max(candidateFontSize, columnWidth).
    /// columnWidth = 0 falls back to candidateFontSize (pre-annotation behavior).
    /// columnWidth > 0 enforces vertical mode column alignment across rows.
    private var candidateMinWidthConstraint: NSLayoutConstraint!
    /// Active when annotation is empty — forces annotation slot to zero
    /// width so any baseline padding NSTextField reserves doesn't leak
    /// into the row layout (would shift trailing edge a few pt right).
    private var annotationZeroWidthConstraint: NSLayoutConstraint!
    private var hasAnnotation: Bool = false

    /// indexWidth=0 collapses the gap so left/right padding match
    /// (symmetric inset within highlight).
    static var effectiveGap: CGFloat {
        indexWidth > 0 ? indexCandidateGap : max(0, defaultTrailingPadding - leadingPadding)
    }

    init(style: CandidateWindow.Style = .sequoia) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        if style == .tahoe {
            let v = NSView()
            v.wantsLayer = true
            addSubview(v)
            highlightView = v
        }

        indexLabel.font = .systemFont(ofSize: Self.indexFontSize)
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.alignment = .center

        candidateLabel.font = .systemFont(ofSize: Self.candidateFontSize)
        candidateLabel.lineBreakMode = .byTruncatingTail
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateLabel.setContentHuggingPriority(.required, for: .horizontal)

        annotationLabel.font = .systemFont(ofSize: Self.annotationFontSize)
        annotationLabel.lineBreakMode = .byTruncatingTail
        annotationLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indexLabel)
        addSubview(candidateLabel)
        addSubview(annotationLabel)

        trailingConstraint = annotationLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -Self.defaultTrailingPadding)
        indexLabelWidthConstraint = indexLabel.widthAnchor.constraint(equalToConstant: Self.indexWidth)
        indexCandidateGapConstraint = candidateLabel.leadingAnchor.constraint(
            equalTo: indexLabel.trailingAnchor, constant: Self.effectiveGap)
        candidateAnnotationGapConstraint = annotationLabel.leadingAnchor.constraint(
            equalTo: candidateLabel.trailingAnchor, constant: 0)
        annotationZeroWidthConstraint = annotationLabel.widthAnchor.constraint(equalToConstant: 0)
        annotationZeroWidthConstraint.priority = .defaultHigh
        annotationZeroWidthConstraint.isActive = true
        candidateMinWidthConstraint = candidateLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.candidateFontSize)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPadding),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabelWidthConstraint,
            indexCandidateGapConstraint,
            candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            candidateAnnotationGapConstraint,
            annotationLabel.centerYAnchor.constraint(equalTo: candidateLabel.centerYAnchor),
            trailingConstraint,
            candidateMinWidthConstraint,
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize + Self.verticalPadding),
        ])
    }

    /// Vertical panel calls this to align all rows' candidate labels to the
    /// same column width (= max candidate intrinsic width across visible
    /// candidates). Width = 0 falls back to the candidateFontSize floor,
    /// matching pre-annotation behavior. State-change guard avoids unnecessary
    /// constraint mutation when called repeatedly with the same value.
    func setCandidateColumnWidth(_ width: CGFloat) {
        let newConstant = max(Self.candidateFontSize, width)
        guard candidateMinWidthConstraint.constant != newConstant else { return }
        candidateMinWidthConstraint.constant = newConstant
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let candidateWidth = max(
            ceil(candidateLabel.intrinsicContentSize.width),
            candidateMinWidthConstraint.constant
        )
        let annotationGap = hasAnnotation ? Self.candidateAnnotationGap : 0
        let annotationWidth = hasAnnotation ? ceil(annotationLabel.intrinsicContentSize.width) : 0
        let w = Self.leadingPadding + Self.indexWidth + Self.effectiveGap + candidateWidth
            + annotationGap + annotationWidth + Self.defaultTrailingPadding
        let h = Self.itemHeight
        return NSSize(width: ceil(w), height: h)
    }

    func configure(label: String, candidate: Candidate) {
        // Sync index-side constraints to current static metrics on every
        // reconfigure — protects against item recycling (constants stay
        // fresh even when updateIndexLabels has run since item init).
        indexLabelWidthConstraint.constant = Self.indexWidth
        indexCandidateGapConstraint.constant = Self.effectiveGap
        indexLabel.stringValue = label
        candidateLabel.stringValue = candidate.text

        // annotation already normalized by Candidate.init: "" → nil
        let willHaveAnnotation = candidate.annotation != nil
        annotationLabel.stringValue = candidate.annotation ?? ""
        candidateAnnotationGapConstraint.constant = willHaveAnnotation ? Self.candidateAnnotationGap : 0
        if willHaveAnnotation != hasAnnotation {
            annotationZeroWidthConstraint.isActive = !willHaveAnnotation
            hasAnnotation = willHaveAnnotation
        }

        invalidateIntrinsicContentSize()
    }

    static var itemHeight: CGFloat { candidateFontSize + verticalPadding }
    static var baseWidth: CGFloat { leadingPadding + indexWidth + effectiveGap + candidateFontSize + defaultTrailingPadding }

    private static var templateView: MacishCandidateItemView?

    private static var sharedTemplateView: MacishCandidateItemView {
        if let view = templateView { return view }
        let view = MacishCandidateItemView()
        templateView = view
        return view
    }

    /// Label is irrelevant to width: `Self.indexWidth` is a hard-equality
    /// constraint that fixes the index slot regardless of label content.
    static func measureWidth(_ candidate: Candidate) -> CGFloat {
        let view = sharedTemplateView
        view.configure(label: "", candidate: candidate)
        return ceil(view.fittingSize.width)
    }

    /// Single-label width measurement via NSTextField intrinsic. Same source
    /// as Auto Layout reads at runtime, ensuring panel-level measurements
    /// align with what the constraint solver will produce. Used by vertical
    /// panel for column alignment instead of full row fittingSize.
    static func measureCandidateLabelWidth(_ text: String) -> CGFloat {
        let view = sharedTemplateView
        view.candidateLabel.stringValue = text
        return ceil(view.candidateLabel.intrinsicContentSize.width)
    }

    static func measureAnnotationLabelWidth(_ text: String) -> CGFloat {
        let view = sharedTemplateView
        view.annotationLabel.stringValue = text
        return ceil(view.annotationLabel.intrinsicContentSize.width)
    }

    override func mouseUp(with event: NSEvent) {
        guard (window as? CandidateItemClickable)?.didDrag != true else { return }
        (window as? CandidateItemClickable)?.itemClicked(at: absoluteIndex, doubleClick: event.clickCount >= 2)
    }

    override func layout() {
        super.layout()
        if let hv = highlightView, isHighlighted {
            let insetRect = bounds.insetBy(dx: contentInset, dy: contentInset)
            hv.frame = insetRect
            hv.layer?.cornerRadius = insetRect.height / 2
        }
    }

    private func updateAppearance() {
        if isHighlighted {
            indexLabel.textColor = .white
            candidateLabel.textColor = .white
            annotationLabel.textColor = .white
            if let hv = highlightView {
                layer?.backgroundColor = nil
                let insetRect = bounds.insetBy(dx: contentInset, dy: contentInset)
                hv.frame = insetRect
                hv.layer?.cornerRadius = insetRect.height / 2
                hv.layer?.backgroundColor = highlightColor.cgColor
                hv.isHidden = false
            } else {
                layer?.backgroundColor = highlightColor.cgColor
            }
        } else {
            indexLabel.textColor = .secondaryLabelColor
            candidateLabel.textColor = .labelColor
            annotationLabel.textColor = .secondaryLabelColor
            if let hv = highlightView {
                hv.isHidden = true
            } else {
                layer?.backgroundColor = nil
            }
        }
    }
}
