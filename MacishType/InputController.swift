import Cocoa
import InputMethodKit
import OSLog

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}

@objc(InputController)
class InputController: IMKInputController {
    private var engine: InputEngine!
    private var engineContext: InputEngineContext!

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

    // MARK: - Input Mode

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        Logger.inputController.debug("setValue ctrl=\("\(ObjectIdentifier(self))", privacy: .public) tag=\(tag, privacy: .public) value=\(String(describing: value), privacy: .public) client=\(clientID, privacy: .public)")
        #endif
        if let modeID = value as? String {
            switchEngine(to: modeID)
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    private func switchEngine(to inputModeID: String) {
        guard let newEngine = InputEngine.engine(for: inputModeID) else {
            Logger.inputController.fault("switchEngine no match for \(inputModeID, privacy: .public)")
            return
        }
        if engine === newEngine {
            activateEngine()
            return
        }
        #if DEBUG
        Logger.inputController.debug("switchEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) \(inputModeID, privacy: .public)")
        #endif
        deactivateEngine()
        if let client = client() {
            setMarkedText("", client: client)
        }
        if CandidateWindow.shared.candidateDelegate === self {
            hideCandidateWindow()
        }
        engine = newEngine
        engineContext = newEngine.createContext()
        activateEngine()
    }

    private func activateEngine() {
        guard let engine else { return }
        #if DEBUG
        Logger.inputController.debug("activateEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\("\(type(of: engine))", privacy: .public)")
        #endif
        CandidateWindow.shared.indexBase = engine.indexBase
        CandidateWindow.shared.pageSize = engine.pageSize
        if let client = client() {
            let actions = engine.activate(
                context: engineContext,
                clientIdentifier: client.bundleIdentifier())
            executeActions(actions, client: client)
        }
    }

    private func deactivateEngine() {
        guard let engine, let engineContext else { return }
        #if DEBUG
        Logger.inputController.debug("deactivateEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\("\(type(of: engine))", privacy: .public)")
        #endif
        let client = client()
        let actions = engine.deactivate(
            context: engineContext,
            clientIdentifier: client?.bundleIdentifier())
        if let client {
            executeActions(actions, client: client)
        }
    }

    // MARK: - IMK Lifecycle

    override func activateServer(_ sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        Logger.inputController.debug("activateServer ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\(self.engine == nil ? "nil" : "set", privacy: .public) client=\(clientID, privacy: .public)")
        #endif
        super.activateServer(sender)
        hideCandidateWindow()
        CandidateWindow.shared.candidateDelegate = self
        CandidateWindow.shared.bundleIdentifier = (sender as? IMKTextInput)?.bundleIdentifier()
    }

    override func deactivateServer(_ sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        Logger.inputController.debug("deactivateServer ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\(self.engine == nil ? "nil" : "set", privacy: .public) client=\(clientID, privacy: .public)")
        #endif
        deactivateEngine()
        if CandidateWindow.shared.candidateDelegate === self {
            hideCandidateWindow()
        }
        super.deactivateServer(sender)
    }

    // MARK: - Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        let result = engine.handleKey(
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
                updateCandidates(candidates, client: client)
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

    private func updateCandidates(_ candidates: [String], client: IMKTextInput) {
        guard !candidates.isEmpty else {
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
        let actions = engine.candidateConfirmed(context: engineContext, candidate)
        executeActions(actions, client: client)
    }

    func candidateSelectionChanged(_ candidate: String) {
        guard let client = client() else { return }
        let actions = engine.candidateSelectionChanged(context: engineContext, candidate)
        executeActions(actions, client: client)
    }
}
