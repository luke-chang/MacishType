import Cocoa

class MacishCandidateWindow: CandidateWindowImpl {

    let style: CandidateWindow.Style

    init(style: CandidateWindow.Style) {
        self.style = style
    }

    private lazy var horizontalPanel = MacishHorizontalExpandablePanel(style: style)
    private lazy var horizontalSimplePanel = MacishHorizontalSimplePanel(style: style)
    private lazy var verticalPanel = MacishVerticalPanel(style: style)

    private var activePanel: MacishBasePanel!

    private func panel(for direction: CandidateWindow.LayoutDirection,
                       expandable: Bool) -> MacishBasePanel {
        let panel: MacishBasePanel = switch direction {
        case .horizontal:
            expandable ? horizontalPanel : horizontalSimplePanel
        case .vertical:
            verticalPanel
        }
        panel.impl = self
        return panel
    }

    // MARK: - Panel Switching

    private func transitionPanel(from oldPanel: MacishBasePanel,
                                 to newPanel: MacishBasePanel,
                                 configuration: CandidateWindowConfiguration) {
        let wasVisible = oldPanel.isVisible
        oldPanel.hide()
        newPanel.apply(configuration)
        newPanel.clientAppearanceDidChange()
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

    override func clientAppearanceDidChange() {
        activePanel.clientAppearanceDidChange()
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
