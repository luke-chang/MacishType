import Cocoa

class SequoiaPageArrowView: NSView {
    var onPageUp: (() -> Void)?
    var onPageDown: (() -> Void)?

    var canPageUp: Bool = false {
        didSet { upImageView.contentTintColor = canPageUp ? .secondaryLabelColor : .tertiaryLabelColor }
    }

    var canPageDown: Bool = false {
        didSet { downImageView.contentTintColor = canPageDown ? .secondaryLabelColor : .tertiaryLabelColor }
    }

    private let separator = NSBox()
    private let upImageView: NSImageView
    private let downImageView: NSImageView
    private var leadingConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var upCenterYConstraint: NSLayoutConstraint!
    private var downCenterYConstraint: NSLayoutConstraint!
    private var currentFontSize: CGFloat = 16
    private var spacing: CGFloat = 4
    private var imageWidth: CGFloat = 16
    private var padding: CGFloat = 6

    override init(frame: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        upImageView = NSImageView(image:
            NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!
                .withSymbolConfiguration(config)!)
        downImageView = NSImageView(image:
            NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
                .withSymbolConfiguration(config)!)

        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        upImageView.contentTintColor = .tertiaryLabelColor
        upImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(upImageView)

        downImageView.contentTintColor = .tertiaryLabelColor
        downImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(downImageView)

        leadingConstraint = upImageView.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: spacing)
        widthConstraint = upImageView.widthAnchor.constraint(equalToConstant: imageWidth)
        trailingConstraint = upImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)
        upCenterYConstraint = upImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4)
        downCenterYConstraint = downImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.heightAnchor.constraint(equalTo: heightAnchor),
            leadingConstraint,
            widthConstraint,
            trailingConstraint,
            upCenterYConstraint,
            downImageView.leadingAnchor.constraint(equalTo: upImageView.leadingAnchor),
            downImageView.widthAnchor.constraint(equalTo: upImageView.widthAnchor),
            downCenterYConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateFontSize(_ candidateFontSize: CGFloat) {
        guard candidateFontSize != currentFontSize else { return }
        currentFontSize = candidateFontSize
        let scale = candidateFontSize / 16
        let newImageWidth = round(16 * scale)
        let newSpacing = round(4 * scale)
        let newPadding = round(6 * scale)
        let newOffset = round(4 * scale)

        let config = NSImage.SymbolConfiguration(pointSize: round(8 * scale), weight: .medium)
        upImageView.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        downImageView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!

        leadingConstraint.constant = newSpacing
        widthConstraint.constant = newImageWidth
        trailingConstraint.constant = -newPadding
        upCenterYConstraint.constant = -newOffset
        downCenterYConstraint.constant = newOffset

        spacing = newSpacing
        imageWidth = newImageWidth
        padding = newPadding
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        // separator(1) + spacing + image + padding
        NSSize(width: 1 + spacing + imageWidth + padding, height: NSView.noIntrinsicMetric)
    }

    override func mouseUp(with event: NSEvent) {
        guard (window as? CandidateItemClickable)?.didDrag != true else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        // NSView default: y=0 at bottom, so y > midY = upper half
        if localPoint.y > bounds.midY {
            if canPageUp { onPageUp?() }
        } else {
            if canPageDown { onPageDown?() }
        }
    }
}
