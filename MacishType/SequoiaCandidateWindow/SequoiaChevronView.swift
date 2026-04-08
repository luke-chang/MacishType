import Cocoa

class SequoiaChevronView: NSView {
    var onClick: (() -> Void)?

    private let separator = NSBox()
    private let imageView: NSImageView

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

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.heightAnchor.constraint(equalTo: heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        // separator(1) + spacing(4) + image(16) + padding(6)
        NSSize(width: 27, height: NSView.noIntrinsicMetric)
    }

    override func mouseUp(with event: NSEvent) {
        if (window as? CandidateItemClickable)?.didDrag != true {
            onClick?()
        }
    }
}
