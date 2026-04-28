import Cocoa

class MacishCandidateItemView: NSView {
    private static var candidateFontSize: CGFloat = 16
    private static var indexFontSize: CGFloat = 8
    private static var indexWidth: CGFloat = computeIndexWidth(labels: "1234567890", fontSize: 8)
    private static var leadingPadding: CGFloat = 4
    private static var indexCandidateGap: CGFloat = 6
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
        leadingPadding = round(4 * scale)
        indexCandidateGap = round(6 * scale)
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

        addSubview(indexLabel)
        addSubview(candidateLabel)

        trailingConstraint = candidateLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -Self.defaultTrailingPadding)
        indexLabelWidthConstraint = indexLabel.widthAnchor.constraint(equalToConstant: Self.indexWidth)
        indexCandidateGapConstraint = candidateLabel.leadingAnchor.constraint(
            equalTo: indexLabel.trailingAnchor, constant: Self.effectiveGap)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPadding),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabelWidthConstraint,
            indexCandidateGapConstraint,
            candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingConstraint,
            candidateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize + Self.verticalPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let candidateWidth = max(
            Self.candidateFontSize,
            ceil(candidateLabel.intrinsicContentSize.width)
        )
        let w = Self.leadingPadding + Self.indexWidth + Self.effectiveGap + candidateWidth + Self.defaultTrailingPadding
        let h = Self.itemHeight
        return NSSize(width: ceil(w), height: h)
    }

    func configure(label: String, candidate: String) {
        // Sync constraints to current static metrics on every reconfigure
        // — protects against item recycling (constants stay fresh even
        // when updateIndexLabels has run since item init).
        indexLabelWidthConstraint.constant = Self.indexWidth
        indexCandidateGapConstraint.constant = Self.effectiveGap
        indexLabel.stringValue = label
        candidateLabel.stringValue = candidate
        invalidateIntrinsicContentSize()
    }

    static var itemHeight: CGFloat { candidateFontSize + verticalPadding }
    static var baseWidth: CGFloat { leadingPadding + indexWidth + effectiveGap + candidateFontSize + defaultTrailingPadding }

    private static var templateView: MacishCandidateItemView?

    /// Label is irrelevant to width: `Self.indexWidth` is a hard-equality
    /// constraint that fixes the index slot regardless of label content.
    static func measureWidth(candidate: String) -> CGFloat {
        let view = templateView ?? {
            let v = MacishCandidateItemView()
            templateView = v
            return v
        }()
        view.configure(label: "", candidate: candidate)
        return ceil(view.fittingSize.width)
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
            if let hv = highlightView {
                hv.isHidden = true
            } else {
                layer?.backgroundColor = nil
            }
        }
    }
}
