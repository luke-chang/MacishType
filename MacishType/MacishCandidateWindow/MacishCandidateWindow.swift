import Cocoa

class MacishCandidateWindow: CandidateWindowImpl {

    let style: CandidateWindow.Style

    init(style: CandidateWindow.Style) {
        self.style = style
        _ = ThemeManager.shared
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
        newPanel.syncTheme()
        if !candidates.isEmpty {
            newPanel.buildCandidateLayout()
            newPanel.restoreSelection(to: selectedIndex)
        }
        if wasVisible {
            newPanel.show(near: lastShowNearRect)
        }
    }

    override func syncTheme() {
        activePanel.syncTheme()
    }

    // MARK: - Delegated Interface

    override var isVisible: Bool { activePanel.isVisible }

    override func apply(_ configuration: CandidateWindowConfiguration) {
        let oldPanel = activePanel
        let newPanel = panel(for: configuration.layoutDirection,
                             expandable: configuration.expandable)
        activePanel = newPanel

        if let oldPanel, oldPanel !== newPanel {
            transitionPanel(from: oldPanel, to: newPanel, configuration: configuration)
        } else {
            newPanel.apply(configuration)
        }
    }

    override func updateCandidates(_ candidates: [String]) {
        updateCandidates(candidates, suspendHighlight: false)
    }

    override func updateCandidates(_ candidates: [String], suspendHighlight: Bool) {
        // Set the flag BEFORE the panel rebuilds layout so that any
        // highlight/notify inside buildCandidateLayout respects it.
        self.suspendHighlight = suspendHighlight
        activePanel.updateCandidates(candidates)
    }

    override func show(near rect: NSRect) {
        activePanel.show(near: rect)
    }

    override func hide() {
        activePanel.hide()
    }

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        if suspendHighlight {
            switch direction {
            case .up, .down, .left, .right, .itemForward, .itemBackward:
                // Pure directional keys: reveal the existing selection
                // (index 0) without advancing.
                activePanel.moveSelection(to: selectedIndex)
                return
            case .home, .end, .pageUp, .pageDown, .pageForward, .pageBackward:
                // Pagination / jump keys: treat index 0 as the starting
                // point and let the panel run its normal logic. moveSelection
                // inside the panel will clear the flag and highlight the
                // destination.
                break
            }
        }
        activePanel.handleNavigation(direction: direction, wrapping: wrapping)
    }

    override func commitSelectedCandidate() {
        // When no item is actively highlighted, report an empty selection
        // to the delegate. Callers can interpret "" however they want (for
        // example, fall back to committing only the surrounding marked
        // text, or treat it as a no-op).
        if suspendHighlight {
            candidateDelegate?.candidateConfirmed("")
            return
        }
        activePanel.commitSelectedCandidate()
    }

    override func commitCandidateForDigit(_ digit: Int) {
        activePanel.commitCandidateForDigit(digit)
    }
}
