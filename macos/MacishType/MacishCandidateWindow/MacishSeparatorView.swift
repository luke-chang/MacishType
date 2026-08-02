import Cocoa

class MacishSeparatorView: NSView {
    var horizontalInset: CGFloat = 0 {
        didSet { if horizontalInset != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.insetBy(dx: horizontalInset, dy: 0).fill()
    }
}
