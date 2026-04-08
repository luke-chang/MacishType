import Cocoa

class SequoiaSeparatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}
