import Cocoa

class MacishHorizontalBasePanel: MacishBasePanel {

    /// Window-width column floor: narrow `pageSize` still yields a window this wide.
    static let minPageSlotColumns = 4

    /// Per-page packing cap; also the slot-width floor in layout.
    var maxPageSlotWidth: CGFloat {
        baseColumnWidth * CGFloat(max(pageSize, Self.minPageSlotColumns))
    }

    /// Greedily packs one row starting at `offset`: up to `pageSize` items,
    /// each clamped to `baseColumnWidth...maxPageSlotWidth`, breaking before
    /// the row width overflows `maxPageSlotWidth` — unless the row is still
    /// empty, so a single oversized candidate always gets a row.
    func packRow(startingAt offset: Int) -> (items: [(candidateIndex: Int, width: CGFloat)], nextOffset: Int) {
        var items: [(candidateIndex: Int, width: CGFloat)] = []
        var usedWidth: CGFloat = 0
        var offset = offset
        while items.count < pageSize, offset < displayCount {
            let raw = MacishCandidateItemView.measureWidth(candidates[offset])
            let width = max(baseColumnWidth, min(raw, maxPageSlotWidth))
            if usedWidth + width > maxPageSlotWidth, !items.isEmpty { break }
            items.append((offset, width))
            usedWidth += width
            offset += 1
        }
        return (items, offset)
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
