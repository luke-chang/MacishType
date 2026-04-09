import Cocoa

class SequoiaCandidateWindow: CandidateWindowImpl {

    private lazy var horizontalPanel = SequoiaHorizontalPanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    private lazy var verticalPanel = SequoiaVerticalPanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    private var activePanel: SequoiaBasePanel { panel(for: direction) }

    private func panel(for direction: CandidateWindow.LayoutDirection) -> SequoiaBasePanel {
        let panel: SequoiaBasePanel = switch direction {
        case .horizontal: horizontalPanel
        case .vertical: verticalPanel
        }
        panel.impl = self
        return panel
    }

    // MARK: - Direction Switching

    override func directionDidChange(from oldDirection: CandidateWindow.LayoutDirection) {
        let oldPanel = panel(for: oldDirection)
        let newPanel = activePanel
        guard oldPanel !== newPanel else { return }

        let wasVisible = oldPanel.isVisible
        oldPanel.hide()

        newPanel.apply(lastAppliedConfiguration)
        newPanel.updateHighlightColor()
        if !candidates.isEmpty {
            newPanel.buildCandidateLayout()
            newPanel.restoreSelection(to: selectedIndex)
        }

        if wasVisible {
            newPanel.show(near: lastShowNearRect)
        }
    }

    override func bundleIdentifierDidChange() {
        activePanel.bundleIdentifierDidChange()
    }

    // MARK: - Delegated Interface

    override var isVisible: Bool { activePanel.isVisible }

    override func apply(_ configuration: CandidateWindowConfiguration) {
        super.apply(configuration)
        activePanel.apply(configuration)
    }

    override func updateCandidates(_ candidates: [String]) {
        activePanel.updateCandidates(candidates)
    }

    override func show(near rect: NSRect) {
        activePanel.show(near: rect)
    }

    override func hide() {
        activePanel.hide()
    }

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        activePanel.handleNavigation(direction: direction, wrapping: wrapping)
    }

    override func commitSelectedCandidate() {
        activePanel.commitSelectedCandidate()
    }

    override func commitCandidateForDigit(_ digit: Int) {
        activePanel.commitCandidateForDigit(digit)
    }
}
