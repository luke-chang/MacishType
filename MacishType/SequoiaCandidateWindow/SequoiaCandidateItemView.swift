import Cocoa

class SequoiaCandidateItemView: NSView {
    private static let indexFontSize: CGFloat = 8
    private static let candidateFontSize: CGFloat = 16
    private static let indexWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: indexFontSize)
        return (0...9).map { digit in
            ceil(("\(digit)" as NSString).size(withAttributes: [.font: font]).width)
        }.max()!
    }()

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

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: Self.indexWidth),
            candidateLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            candidateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            candidateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.candidateFontSize + 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let candidateWidth = max(
            Self.candidateFontSize,
            ceil(candidateLabel.intrinsicContentSize.width)
        )
        let w = 5 + Self.indexWidth + 6 + candidateWidth + 7
        let h = Self.candidateFontSize + 12
        return NSSize(width: ceil(w), height: h)
    }

    func configure(index: Int, candidate: String) {
        indexLabel.stringValue = "\(index)"
        candidateLabel.stringValue = candidate
        invalidateIntrinsicContentSize()
    }

    private static let templateView = SequoiaCandidateItemView()

    static func measureWidth(index: Int, candidate: String) -> CGFloat {
        templateView.configure(index: index, candidate: candidate)
        return ceil(templateView.fittingSize.width)
    }

    static var measureHeight: CGFloat {
        ceil(templateView.fittingSize.height)
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
