import Cocoa

class MacishCandidateItemView: NSView {
    /// Reference values at candidateFontSize=16; runtime metrics scale linearly.
    private struct Base16Metrics {
        static let candidateFontSize: CGFloat = 16
        static let indexFontSize: CGFloat = 8
        static let annotationFontSize: CGFloat = 12
        static let leadingPadding: CGFloat = 4
        static let indexCandidateGap: CGFloat = 2
        static let candidateAnnotationGap: CGFloat = 11
        static let defaultTrailingPadding: CGFloat = 9
        static let verticalPadding: CGFloat = 12
    }

    static private(set) var candidateFontSize: CGFloat = Base16Metrics.candidateFontSize
    private static var indexFontSize: CGFloat = Base16Metrics.indexFontSize
    private static var annotationFontSize: CGFloat = Base16Metrics.annotationFontSize
    private static var indexColumnEnabled: Bool = true
    static var indexWidth: CGFloat {
        indexColumnEnabled ? indexFontSize + 2 : 0
    }
    // Tied to the indexWidth-slot center math — raising this without
    // re-checking digit positions across fontSizes will shift the column.
    static private(set) var leadingPadding: CGFloat = Base16Metrics.leadingPadding
    private static var indexCandidateGap: CGFloat = Base16Metrics.indexCandidateGap
    static private(set) var candidateAnnotationGap: CGFloat = Base16Metrics.candidateAnnotationGap
    static private(set) var defaultTrailingPadding: CGFloat = Base16Metrics.defaultTrailingPadding
    private static var verticalPadding: CGFloat = Base16Metrics.verticalPadding

    static func updateFontSize(_ newSize: CGFloat) {
        let size = max(newSize, 8)
        guard size != candidateFontSize else { return }
        let scale = size / Base16Metrics.candidateFontSize
        candidateFontSize = size
        indexFontSize = round(Base16Metrics.indexFontSize * scale)
        annotationFontSize = round(Base16Metrics.annotationFontSize * scale)
        leadingPadding = round(Base16Metrics.leadingPadding * scale)
        indexCandidateGap = round(Base16Metrics.indexCandidateGap * scale)
        candidateAnnotationGap = round(Base16Metrics.candidateAnnotationGap * scale)
        defaultTrailingPadding = round(Base16Metrics.defaultTrailingPadding * scale)
        verticalPadding = round(Base16Metrics.verticalPadding * scale)
        templateView = nil
    }

    /// Toggle the index-column slot. Per-position label content is
    /// rendered independently — pass a blank label to keep the slot empty.
    static func configureIndexColumn(enabled: Bool) {
        guard enabled != indexColumnEnabled else { return }
        indexColumnEnabled = enabled
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
        didSet {
            guard isHighlighted != oldValue else { return }
            updateAppearance()
        }
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

    /// When the index column is disabled, gap collapses to keep left/right
    /// padding symmetric within the highlight.
    static var effectiveGap: CGFloat {
        indexColumnEnabled ? indexCandidateGap : max(0, defaultTrailingPadding - leadingPadding)
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
        let hasAnnotation = !annotationLabel.stringValue.isEmpty
        let annotationGap = hasAnnotation ? Self.candidateAnnotationGap : 0
        let annotationWidth = hasAnnotation ? ceil(annotationLabel.intrinsicContentSize.width) : 0
        let w = Self.leadingPadding + Self.indexWidth + Self.effectiveGap + candidateWidth
            + annotationGap + annotationWidth + Self.defaultTrailingPadding
        let h = Self.itemHeight
        return NSSize(width: ceil(w), height: h)
    }

    func configure(label: String, candidate: Candidate) {
        // Sync index-side constraints to current static metrics on every
        // reconfigure — protects against item recycling. Guarded so a
        // recycled item with already-current values doesn't dirty Auto Layout.
        if indexLabelWidthConstraint.constant != Self.indexWidth {
            indexLabelWidthConstraint.constant = Self.indexWidth
        }
        if indexCandidateGapConstraint.constant != Self.effectiveGap {
            indexCandidateGapConstraint.constant = Self.effectiveGap
        }
        indexLabel.stringValue = label
        candidateLabel.stringValue = candidate.text

        // annotation already normalized by Candidate.init: "" → nil
        let willHaveAnnotation = candidate.annotation != nil
        annotationLabel.stringValue = candidate.annotation ?? ""
        candidateAnnotationGapConstraint.constant = willHaveAnnotation ? Self.candidateAnnotationGap : 0
        let shouldZeroAnnotation = !willHaveAnnotation
        if annotationZeroWidthConstraint.isActive != shouldZeroAnnotation {
            annotationZeroWidthConstraint.isActive = shouldZeroAnnotation
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
