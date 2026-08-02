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
        // Skip migration when hidden: moveSelection can reach expandWindow,
        // which orders the window front on its own, resurrecting stale candidates.
        if wasVisible {
            if !candidates.isEmpty {
                newPanel.buildCandidateLayout()
                // selectedIndex is shared via impl; -1 is preserved naturally.
                newPanel.moveSelection(to: selectedIndex, animated: false)
            }
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

    override func updateCandidates(_ candidates: [Candidate], initialHighlight: Int,
                                   configuration: CandidateWindowConfiguration?) {
        var pendingTransition: (oldPanel: MacishBasePanel, nearRect: NSRect)?

        if let cfg = configuration {
            let oldPanel = activePanel
            let newPanel = panel(for: cfg.layoutDirection, expandable: cfg.expandable)
            activePanel = newPanel

            if let oldPanel, oldPanel !== newPanel {
                // Cross-panel: keep oldPanel visible until newPanel has
                // data, then swap below — avoids empty-window flash.
                newPanel.apply(cfg, deferRender: true)
                newPanel.syncTheme()
                pendingTransition = oldPanel.isVisible
                    ? (oldPanel, oldPanel.lastShowNearRect)
                    : nil
            } else {
                newPanel.apply(cfg, deferRender: true)
            }
        }

        activePanel.updateCandidates(candidates, initialIndex: initialHighlight)

        if let pending = pendingTransition {
            activePanel.show(near: pending.nearRect)
            pending.oldPanel.hide()
        }
    }

    override func show(near rect: NSRect) {
        activePanel.show(near: rect)
    }

    override func hide() {
        activePanel.hide()
    }

    override func handleNavigation(direction: NavigationDirection, wrapping: Bool) {
        // A hidden panel still holds stale candidates; don't navigate them.
        guard activePanel.isVisible else { return }
        if !hasSelection {
            switch direction {
            case .up, .down, .left, .right, .itemForward, .itemBackward:
                // Arrow keys only reveal the first candidate on the first press
                // from a suspended highlight; they don't move yet.
                activePanel.moveSelection(to: 0)
                return
            default:
                // Page keys and .home / .end fall through: panels treat the -1
                // sentinel as index 0, so page keys jump (and expandable panels
                // expand) instead of merely revealing the first candidate.
                break
            }
        }
        activePanel.handleNavigation(direction: direction, wrapping: wrapping)
        // Reveal at 0 when the panel short-circuited from the suspended state
        // (e.g. .home or pageUp on the first page) and left selection unchanged.
        if !hasSelection {
            activePanel.moveSelection(to: 0)
        }
    }

    override func commitSelectedCandidate() {
        // When no item is selected, report an empty commit to the delegate.
        // Callers can interpret "" / -1 however they want (fall back to
        // committing surrounding marked text, treat as no-op, etc).
        if !hasSelection {
            candidateDelegate?.candidateConfirmed("", absoluteIndex: -1, raw: nil)
            return
        }
        activePanel.commitSelectedCandidate()
    }

    override func commitCandidate(at index: Int) {
        activePanel.commitCandidate(at: index)
    }
}
