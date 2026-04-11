import Cocoa

class SequoiaCandidateWindow: CandidateWindowImpl {

    private lazy var horizontalPanel = SequoiaHorizontalExpandablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    private lazy var horizontalSimplePanel = SequoiaHorizontalSimplePanel(
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

    private var activePanel: SequoiaBasePanel!

    private func panel(for direction: CandidateWindow.LayoutDirection,
                       expandable: Bool) -> SequoiaBasePanel {
        let panel: SequoiaBasePanel = switch direction {
        case .horizontal:
            expandable ? horizontalPanel : horizontalSimplePanel
        case .vertical:
            verticalPanel
        }
        panel.impl = self
        return panel
    }

    // MARK: - Panel Switching

    private func transitionPanel(from oldPanel: SequoiaBasePanel,
                                 to newPanel: SequoiaBasePanel,
                                 configuration: CandidateWindowConfiguration) {
        let wasVisible = oldPanel.isVisible
        oldPanel.hide()
        newPanel.apply(configuration)
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
        let oldPanel = activePanel
        let newPanel = panel(for: configuration.layoutDirection!,
                             expandable: configuration.expandable)
        activePanel = newPanel

        if let oldPanel, oldPanel !== newPanel {
            transitionPanel(from: oldPanel, to: newPanel, configuration: configuration)
        } else {
            newPanel.apply(configuration)
        }
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
