import Cocoa

class SequoiaHorizontalBasePanel: SequoiaBasePanel {

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
