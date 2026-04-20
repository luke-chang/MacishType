import Cocoa

class MacishCandidateItemView: NSView {
    private static var candidateFontSize: CGFloat = 16
    private static var indexFontSize: CGFloat = 8
    private static var indexWidth: CGFloat = computeIndexWidth(fontSize: 8)
    private static var leadingPadding: CGFloat = 4
    private static var indexCandidateGap: CGFloat = 6
    static private(set) var defaultTrailingPadding: CGFloat = 9
    private static var verticalPadding: CGFloat = 12

    private static func computeIndexWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return (0...9).map { digit in
            ceil(("\(digit)" as NSString).size(withAttributes: [.font: font]).width)
        }.max()!
    }

    static func updateFontSize(_ newSize: CGFloat) {
        let size = max(newSize, 8)
        guard size != candidateFontSize else { return }
        let scale = size / 16
        candidateFontSize = size
        indexFontSize = round(size / 2)
        indexWidth = computeIndexWidth(fontSize: indexFontSize)
        leadingPadding = round(4 * scale)
        indexCandidateGap = round(6 * scale)
        defaultTrailingPadding = round(9 * scale)
        verticalPadding = round(12 * scale)
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

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPadding),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: Self.indexWidth),
            candidateLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: Self.indexCandidateGap),
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
        let w = Self.leadingPadding + Self.indexWidth + Self.indexCandidateGap + candidateWidth + Self.defaultTrailingPadding
        let h = Self.itemHeight
        return NSSize(width: ceil(w), height: h)
    }

    func configure(index: Int, candidate: String) {
        indexLabel.stringValue = "\(index)"
        candidateLabel.stringValue = candidate
        invalidateIntrinsicContentSize()
    }

    static var itemHeight: CGFloat { candidateFontSize + verticalPadding }
    static var baseWidth: CGFloat { leadingPadding + indexWidth + indexCandidateGap + candidateFontSize + defaultTrailingPadding }

    private static var templateView: MacishCandidateItemView?

    static func measureWidth(index: Int, candidate: String) -> CGFloat {
        let view = templateView ?? {
            let v = MacishCandidateItemView()
            templateView = v
            return v
        }()
        view.configure(index: index, candidate: candidate)
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
