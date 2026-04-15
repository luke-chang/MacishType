import Cocoa

class MacishCandidateItemView: NSView {
    private static var candidateFontSize: CGFloat = 16
    private static var indexFontSize: CGFloat = 8
    private static var indexWidth: CGFloat = computeIndexWidth(fontSize: 8)
    private static var leadingPadding: CGFloat = 5
    private static var indexCandidateGap: CGFloat = 6
    private static var defaultTrailingPadding: CGFloat = 7
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
        leadingPadding = round(5 * scale)
        indexCandidateGap = round(6 * scale)
        defaultTrailingPadding = round(7 * scale)
        verticalPadding = round(12 * scale)
        templateView = nil
    }

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

    var reservesScrollerSpace: Bool = false {
        didSet {
            guard reservesScrollerSpace != oldValue else { return }
            let padding: CGFloat = reservesScrollerSpace
                ? max(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), Self.defaultTrailingPadding)
                : Self.defaultTrailingPadding
            trailingConstraint.constant = -padding
        }
    }

    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

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

    private func updateAppearance() {
        if isHighlighted {
            layer?.backgroundColor = highlightColor.cgColor
            indexLabel.textColor = .white
            candidateLabel.textColor = .white
        } else {
            layer?.backgroundColor = nil
            indexLabel.textColor = .secondaryLabelColor
            candidateLabel.textColor = .labelColor
        }
    }
}
