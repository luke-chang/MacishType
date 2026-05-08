import Cocoa

class MacishHorizontalBasePanel: MacishBasePanel {

    /// Window-width column floor: narrow `pageSize` still yields a window this wide.
    static let minPageSlotColumns = 4

    /// Per-page packing cap; also the slot-width floor in layout.
    var maxPageSlotWidth: CGFloat {
        baseColumnWidth * CGFloat(max(pageSize, Self.minPageSlotColumns))
    }

    func applyUniformCorners() {
        super.updateCorners()
    }

    func applyPillCorners(size: NSSize) {
        switch style {
        case .sequoia:
            backdrop.applyAsymmetricCorners(
                size: size,
                leftRadius: Self.defaultCornerRadius,
                rightRadius: size.height / 2
            )
        case .tahoe:
            backdrop.applyUniformCorners(size: size, radius: itemHeight / 2)
        }
    }
}
