import Cocoa

extension NSImage {
    static func asymmetricCornerMask(size: NSSize, leftRadius: CGFloat, rightRadius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let lr = min(leftRadius, rect.height / 2)
            let rr = min(rightRadius, rect.height / 2)
            path.move(to: NSPoint(x: lr, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - rr, y: rect.maxY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - rr, y: rect.maxY - rr),
                           radius: rr, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: rect.maxX, y: rr))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - rr, y: rr),
                           radius: rr, startAngle: 0, endAngle: -90, clockwise: true)
            path.line(to: NSPoint(x: lr, y: 0))
            path.appendArc(withCenter: NSPoint(x: lr, y: lr),
                           radius: lr, startAngle: -90, endAngle: -180, clockwise: true)
            path.line(to: NSPoint(x: 0, y: rect.maxY - lr))
            path.appendArc(withCenter: NSPoint(x: lr, y: rect.maxY - lr),
                           radius: lr, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()
            path.fill()
            return true
        }
    }
}

// MARK: -

class SequoiaHorizontalBasePanel: SequoiaBasePanel {

    private var pillMask: NSImage?
    private var pillMaskSize: NSSize = .zero

    func applyUniformCorners() {
        super.updateMaskImage()
    }

    func applyPillCorners(size: NSSize) {
        visualEffectView.maskImage = pillCornerMask(size: size)
    }

    private func pillCornerMask(size: NSSize) -> NSImage {
        if size == pillMaskSize, let pillMask { return pillMask }
        let lr = Self.defaultCornerRadius
        let rr = size.height / 2
        let mask = NSImage.asymmetricCornerMask(size: size, leftRadius: lr, rightRadius: rr)
        // Only cache the widest mask; height change (font size) always updates.
        if size.width >= pillMaskSize.width || size.height != pillMaskSize.height {
            pillMask = mask
            pillMaskSize = size
        }
        return mask
    }
}
