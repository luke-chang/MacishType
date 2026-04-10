import Cocoa

extension NSImage {
    static func asymmetricCornerMask(height: CGFloat, leftRadius: CGFloat, rightRadius: CGFloat) -> NSImage {
        let rr = min(rightRadius, height / 2)
        let width = leftRadius + rr + 1
        // +1 ensures at least 1pt of stretchable center between top/bottom cap insets,
        // preventing rendering artifacts when the mask is stretched to a taller view.
        let imageHeight = rr * 2 + 1
        let image = asymmetricCornerMask(
            size: NSSize(width: width, height: imageHeight),
            leftRadius: leftRadius, rightRadius: rightRadius
        )
        image.capInsets = NSEdgeInsets(top: rr, left: leftRadius, bottom: rr, right: rr)
        image.resizingMode = .stretch
        return image
    }

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
    private var pillMaskHeight: CGFloat = 0

    func pillCornerMask(height: CGFloat) -> NSImage {
        if height == pillMaskHeight, let pillMask { return pillMask }
        let lr = Self.defaultCornerRadius
        let rr = height / 2
        let mask = NSImage.asymmetricCornerMask(height: height, leftRadius: lr, rightRadius: rr)
        pillMask = mask
        pillMaskHeight = height
        return mask
    }
}
