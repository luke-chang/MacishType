import Cocoa
import InputMethodKit

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}

@objc(InputController)
class InputController: IMKInputController {
    private lazy var engineContext = currentEngine.createContext()

    private lazy var inputMethodMenu: NSMenu = {
        let menu = NSMenu()
        let aboutItem = NSMenuItem(
            title: String(localized: "About MacishType"),
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        return menu
    }()

    override func menu() -> NSMenu! { inputMethodMenu }

    @MainActor @objc private func showAboutWindow(_ sender: Any?) {
        WindowManager.shared.openAbout()
    }

    // MARK: - IMK Lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        hideCandidateWindow()
        CandidateWindow.shared.candidateDelegate = self
        CandidateWindow.shared.bundleIdentifier = (sender as? IMKTextInput)?.bundleIdentifier()
        CandidateWindow.shared.indexBase = currentEngine.indexBase
        CandidateWindow.shared.pageSize = currentEngine.pageSize
        currentEngine.activate(
            context: engineContext,
            clientIdentifier: (sender as? IMKTextInput)?.bundleIdentifier())
    }

    override func deactivateServer(_ sender: Any!) {
        let client = sender as? IMKTextInput
        currentEngine.deactivate(
            context: engineContext,
            clientIdentifier: client?.bundleIdentifier())
        refreshMarkedText(client: client)
        // IMKit may call activateServer on a new controller before deactivateServer
        // on the old one. Only hide the candidate window if we still own it.
        if CandidateWindow.shared.candidateDelegate === self {
            hideCandidateWindow()
        }
        super.deactivateServer(sender)
    }

    // MARK: - Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        let result = currentEngine.handleKey(
            context: engineContext,
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags,
            candidateWindowVisible: CandidateWindow.shared.isVisible)
        switch result {
        case .notHandled:
            return false
        case .handled(let actions):
            executeActions(actions, client: client)
            return true
        }
    }

    // MARK: - Action Executor

    private func executeActions(_ actions: [EngineAction], client: IMKTextInput) {
        for action in actions {
            switch action {
            case .insert(let text):
                client.insertText(text, replacementRange: .notFound)
            case .updateMarkedText(let text):
                setMarkedText(text, client: client)
            case .updateCandidates(let candidates):
                updateCandidates(candidates.isEmpty ? nil : candidates, client: client)
            case .commitSelectedCandidate:
                CandidateWindow.shared.commitSelectedCandidate()
            case .commitCandidateByDigit(let digit):
                CandidateWindow.shared.commitCandidateForDigit(digit)
            case .navigateCandidates(let direction, let wrapping):
                CandidateWindow.shared.handleNavigation(direction: direction, wrapping: wrapping)
            case .noop:
                break
            }
        }
    }

    // MARK: - Marked Text

    private func setMarkedText(_ text: String, client: IMKTextInput) {
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0
            ]
        )
        client.setMarkedText(
            attributedText,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: .notFound
        )
    }

    private func refreshMarkedText(client: IMKTextInput?) {
        guard let client else { return }
        setMarkedText(engineContext.composingText, client: client)
    }

    // MARK: - Candidate Window

    // Some apps (e.g. iMessage) return origin (0, 0) for certain character
    // indices. Start from index 0 to anchor the window at the composition
    // start, and try subsequent indices as fallback.
    // Reference: McBopomofo and vChewing use the same retry pattern.
    private func showCandidateWindow(client: IMKTextInput) {
        var lineHeightRect = NSRect.zero
        let markedTextLength = engineContext.composingText.utf16.count
        var cursor = 0
        while lineHeightRect.origin == .zero && cursor < markedTextLength {
            _ = client.attributes(forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            cursor += 1
        }
        CandidateWindow.shared.showNear(rect: lineHeightRect)
    }

    private func hideCandidateWindow() {
        CandidateWindow.shared.hide()
    }

    private func updateCandidates(_ candidates: [String]?, client: IMKTextInput) {
        guard let candidates, !candidates.isEmpty else {
            hideCandidateWindow()
            return
        }
        CandidateWindow.shared.updateCandidates(candidates)
        showCandidateWindow(client: client)
    }
}

// MARK: - CandidateWindowDelegate

extension InputController: CandidateWindowDelegate {
    func candidateSelected(_ candidate: String) {
        guard let client = client() else { return }
        let actions = currentEngine.candidateConfirmed(context: engineContext, candidate)
        executeActions(actions, client: client)
    }

    func candidateSelectionChanged(_ candidate: String) {
        guard let client = client() else { return }
        let actions = currentEngine.candidateSelectionChanged(context: engineContext, candidate)
        executeActions(actions, client: client)
    }
}
