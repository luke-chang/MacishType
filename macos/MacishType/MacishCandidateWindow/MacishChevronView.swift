import Cocoa

class MacishChevronView: NSView {
    var onClick: (() -> Void)?

    private let style: CandidateWindow.Style
    private let separator = NSBox()
    private let imageView: NSImageView
    private var imageLeadingConstraint: NSLayoutConstraint!
    private var imageWidthConstraint: NSLayoutConstraint!
    private var imageTrailingConstraint: NSLayoutConstraint!
    private var separatorHeightConstraint: NSLayoutConstraint!
    private var currentFontSize: CGFloat = 16
    private var spacing: CGFloat = 5
    private var imageWidth: CGFloat = 16
    private var padding: CGFloat = 6
    private var separatorInset: CGFloat = 0

    init(style: CandidateWindow.Style = .sequoia) {
        self.style = style
        self.separatorInset = style == .tahoe ? 4 : 0
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let chevronImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        imageView = NSImageView(image: chevronImage)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        imageLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: spacing)
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: imageWidth)
        imageTrailingConstraint = imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)
        separatorHeightConstraint = separator.heightAnchor.constraint(equalTo: heightAnchor, constant: -2 * separatorInset)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separatorHeightConstraint,
            imageLeadingConstraint,
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageWidthConstraint,
            imageTrailingConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateFontSize(_ candidateFontSize: CGFloat) {
        guard candidateFontSize != currentFontSize else { return }
        currentFontSize = candidateFontSize
        let scale = candidateFontSize / 16
        let newPointSize = round(11 * scale)
        let newImageWidth = round(16 * scale)
        let newSpacing = round(5 * scale)
        let newPadding = round(6 * scale)

        let config = NSImage.SymbolConfiguration(pointSize: newPointSize, weight: .medium)
        imageView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!

        let newSeparatorInset: CGFloat = style == .tahoe ? 4 : 0

        imageLeadingConstraint.constant = newSpacing
        imageWidthConstraint.constant = newImageWidth
        imageTrailingConstraint.constant = -newPadding
        separatorHeightConstraint.constant = -2 * newSeparatorInset

        spacing = newSpacing
        imageWidth = newImageWidth
        padding = newPadding
        separatorInset = newSeparatorInset
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        // separator(1) + spacing + image + padding
        NSSize(width: 1 + spacing + imageWidth + padding, height: NSView.noIntrinsicMetric)
    }

    var separatorAlphaValue: CGFloat {
        get { separator.alphaValue }
        set { separator.alphaValue = newValue }
    }

    var imageAlphaValue: CGFloat {
        get { imageView.alphaValue }
        set { imageView.alphaValue = newValue }
    }

    func setContentAlpha(_ alpha: CGFloat) {
        separator.alphaValue = alpha
        imageView.alphaValue = alpha
    }

    override func mouseUp(with event: NSEvent) {
        if (window as? CandidateItemClickable)?.didDrag != true {
            onClick?()
        }
    }
}
