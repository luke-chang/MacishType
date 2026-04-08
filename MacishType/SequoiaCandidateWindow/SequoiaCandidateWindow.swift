import Cocoa

class SequoiaCandidateWindow: CandidateWindowImpl {

    private let horizontalPanel = SequoiaHorizontalPanel(
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

    override init() {
        super.init()
        horizontalPanel.impl = self
    }

    private func panel(for direction: CandidateWindow.LayoutDirection) -> SequoiaBasePanel {
        switch direction {
        case .horizontal:
            return horizontalPanel
        case .vertical:
            verticalPanel.impl = self
            return verticalPanel
        }
    }

    // MARK: - Direction Switching

    override func directionDidChange(from oldDirection: CandidateWindow.LayoutDirection) {
        let oldPanel = panel(for: oldDirection)
        let newPanel = activePanel
        guard oldPanel !== newPanel else { return }

        let wasVisible = oldPanel.isVisible
        let savedCandidates = oldPanel.candidates
        let savedSelectedIndex = oldPanel.selectedIndex
        oldPanel.hide()

        newPanel.apply(oldPanel.lastAppliedConfiguration)
        newPanel.updateHighlightColor()
        if !savedCandidates.isEmpty {
            newPanel.updateCandidates(savedCandidates)
            newPanel.restoreSelection(to: savedSelectedIndex)
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
