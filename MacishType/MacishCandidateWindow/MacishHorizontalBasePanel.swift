import Cocoa

class MacishHorizontalBasePanel: MacishBasePanel {

    func applyUniformCorners() {
        super.updateMaskImage()
    }

    func applyPillCorners(size: NSSize) {
        backdrop.applyAsymmetricCorners(
            size: size,
            leftRadius: Self.defaultCornerRadius,
            rightRadius: size.height / 2
        )
    }
}
