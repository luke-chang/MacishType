import Cocoa

class MacishHorizontalBasePanel: MacishBasePanel {

    func applyUniformCorners() {
        super.updateMaskImage()
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
