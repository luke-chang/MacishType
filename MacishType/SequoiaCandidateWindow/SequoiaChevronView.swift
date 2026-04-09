import Cocoa

class SequoiaChevronView: NSView {
    var onClick: (() -> Void)?

    private let separator = NSBox()
    private let imageView: NSImageView
    private var imageLeadingConstraint: NSLayoutConstraint!
    private var imageWidthConstraint: NSLayoutConstraint!
    private var imageTrailingConstraint: NSLayoutConstraint!
    private var currentFontSize: CGFloat = 16
    private var spacing: CGFloat = 4
    private var imageWidth: CGFloat = 16
    private var padding: CGFloat = 6

    override init(frame: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let chevronImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        imageView = NSImageView(image: chevronImage)

        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        imageLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: spacing)
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: imageWidth)
        imageTrailingConstraint = imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.heightAnchor.constraint(equalTo: heightAnchor),
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
        let newPointSize = round(10 * scale)
        let newImageWidth = round(16 * scale)
        let newSpacing = round(4 * scale)
        let newPadding = round(6 * scale)

        let config = NSImage.SymbolConfiguration(pointSize: newPointSize, weight: .medium)
        imageView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!

        imageLeadingConstraint.constant = newSpacing
        imageWidthConstraint.constant = newImageWidth
        imageTrailingConstraint.constant = -newPadding

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
        if (window as? CandidateItemClickable)?.didDrag != true {
            onClick?()
        }
    }
}
