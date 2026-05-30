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
    private var appearanceStale = true

    private lazy var inputMethodMenu: NSMenu = {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(showPreferences(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
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

    @MainActor override func showPreferences(_ sender: Any!) {
        let initialID = engine?.engineID
        WindowManager.shared.openSettings(initialEngineID: initialID)
    }

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
        // Same engine: preserve composition. activateEngine is isActivated-guarded.
        if engine === newEngine {
            activateEngine()
            return
        }
        #if DEBUG
        Logger.inputController.debug("switchEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) \(inputModeID, privacy: .public)")
        #endif
        deactivateEngine()
        engine = newEngine
        engineContext = newEngine.createContext()
        activateEngine()
    }

    private func activateEngine() {
        guard let engine, let engineContext else { return }
        #if DEBUG
        Logger.inputController.debug("activateEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\("\(type(of: engine))", privacy: .public) activated=\(engineContext.isActivated, privacy: .public)")
        #endif
        if !engineContext.isActivated {
            engineContext.isActivated = true
            engine.activate(context: engineContext,
                            clientIdentifier: client()?.bundleIdentifier())
        }
        // Always reconfigure — candidate window is a shared singleton and may
        // have been reconfigured by another controller since we were last active.
        // Must run after engine.activate() so candidateWindowConfiguration reads
        // ivars freshly synced by reloadConfig() in activate().
        CandidateWindow.shared.configure(engine.candidateWindowConfiguration)
    }

    private func deactivateEngine() {
        guard let engine, let engineContext else { return }
        #if DEBUG
        Logger.inputController.debug("deactivateEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\("\(type(of: engine))", privacy: .public) activated=\(engineContext.isActivated, privacy: .public) staged=\(engineContext.stagedText, privacy: .public)")
        #endif
        let currentClient = client()
        endComposition(client: currentClient, insert: engineContext.stagedText)
        if engineContext.isActivated {
            engineContext.isActivated = false
            engine.deactivate(context: engineContext, clientIdentifier: currentClient?.bundleIdentifier())
        }
    }

    // Inserts `insertion` as committed text (which implicitly replaces any
    // marked text), or clears marked text when nil/empty. Then hides candidate
    // window if we own it, and resets context.
    private func endComposition(client: IMKTextInput?, insert insertion: String? = nil) {
        guard let engineContext else { return }
        if let client {
            if let insertion, !insertion.isEmpty {
                client.insertText(insertion, replacementRange: .notFound)
            } else {
                setMarkedText("", client: client)
            }
        }
        if CandidateWindow.shared.candidateDelegate === self {
            hideCandidateWindow()
        }
        engineContext.reset()
    }

    // MARK: - IMK Lifecycle

    override func activateServer(_ sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        let clientLevel = (sender as? IMKTextInput)?.windowLevel() ?? 0
        Logger.inputController.debug("activateServer ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\(self.engine == nil ? "nil" : "set", privacy: .public) client=\(clientID, privacy: .public) windowLevel=\(clientLevel, privacy: .public)")
        #endif
        super.activateServer(sender)
        appearanceStale = true
        hideCandidateWindow()
    }

    override func deactivateServer(_ sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        Logger.inputController.debug("deactivateServer ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\(self.engine == nil ? "nil" : "set", privacy: .public) client=\(clientID, privacy: .public)")
        #endif
        deactivateEngine()
        super.deactivateServer(sender)
    }

    private static let windowEffectiveAppearanceSel = NSSelectorFromString("windowEffectiveAppearance")

    private static func clientAppearance(from sender: Any?) -> NSAppearance? {
        guard let obj = sender as AnyObject?, obj.responds(to: windowEffectiveAppearanceSel) else { return nil }
        return obj.perform(windowEffectiveAppearanceSel)?.takeUnretainedValue() as? NSAppearance
    }

    // Some clients (e.g. Open/Save panels) are XPC services whose bundle ID
    // has no matching .app. Use the frontmost application as the real owner.
    private static func resolvedBundleIdentifier(_ sender: Any?) -> String? {
        guard let clientID = (sender as? IMKTextInput)?.bundleIdentifier() else { return nil }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: clientID) == nil {
            let resolved = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            Logger.inputController.info("Client \(clientID, privacy: .public) is not an app, resolved to \(resolved ?? "nil", privacy: .public)")
            return resolved
        }
        return clientID
    }

    // Called by the system when composition must end (e.g. Cmd+A select
    // all, mouse click outside). Do NOT call super — it triggers an
    // immediate deactivateServer, which crashes or switches away from
    // the input method. stagedText (if any) is committed; rest is dropped.
    override func commitComposition(_ sender: Any!) {
        #if DEBUG
        let clientID = (sender as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        Logger.inputController.debug("commitComposition ctrl=\("\(ObjectIdentifier(self))", privacy: .public) client=\(clientID, privacy: .public) staged=\(self.engineContext?.stagedText ?? "", privacy: .public)")
        #endif
        endComposition(client: sender as? IMKTextInput, insert: engineContext?.stagedText)
    }

    // MARK: - Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput,
              let engine, let engineContext else { return false }
        var themeStale = false
        if CandidateWindow.shared.candidateDelegate !== self {
            CandidateWindow.shared.candidateDelegate = self
            CandidateWindow.shared.bundleIdentifier = Self.resolvedBundleIdentifier(sender)
            CandidateWindow.shared.clientWindowLevel = client.windowLevel()
            themeStale = true
        }
        // Queried once per activation cycle (flag set in activateServer).
        // Separate from the delegate check above because the same controller
        // can be reused across activations within the same app, where the
        // delegate hasn't changed but the client's appearance may have.
        if appearanceStale {
            appearanceStale = false
            let appearance = Self.clientAppearance(from: sender)
            if CandidateWindow.shared.clientAppearance !== appearance {
                CandidateWindow.shared.clientAppearance = appearance
                themeStale = true
            }
        }
        if themeStale {
            CandidateWindow.shared.syncTheme()
        }
        let candidateWindowState = currentCandidateWindowState()
        // charactersIgnoringModifiers is unreliable in IMK: strips Shift along
        // with Option and resolves dead keys to combining marks (Option+E → "´"
        // not "e"). characters(byApplyingModifiers:) routes through the OS
        // layout query and returns the expected base / shifted character.
        let shiftOnly = event.modifierFlags.intersection(.shift)
        let charactersIgnoringModifiers = event.characters(byApplyingModifiers: shiftOnly)
        let keyEvent = KeyEventInput(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            isRepeat: event.isARepeat)
        if engineContext.isAssociating {
            // Tier 1a: policy-gated candidate-window key handling
            if dispatchCandidateWindowKey(keyEvent) {
                return true
            }
            // Tier 1b: engine override point
            switch engine.handleAssociatedKey(
                context: engineContext, keyEvent: keyEvent,
                candidateWindow: candidateWindowState
            ) {
            case .handled(let actions):
                executeActions(actions, client: client)
                return true
            case .notHandled(let actions):
                // Tier 2: dismiss + fall through to engine.handleKey
                executeActions(actions + [.flushStaged()], client: client)
            }
        } else if dispatchCandidateWindowKey(keyEvent) {
            return true
        }
        let result = engine.handleKey(
            context: engineContext,
            keyEvent: keyEvent,
            candidateWindow: candidateWindowState)
        switch result {
        case .handled(let actions):
            executeActions(actions, client: client)
            return true
        case .notHandled(let actions):
            executeActions(actions, client: client)
            return false
        }
    }

    // MARK: - Action Executor

    private func executeActions(_ actions: [EngineAction], client: IMKTextInput) {
        for action in actions {
            switch action {
            case .updateMarkedText(let text, let cursor, let emphasis, let staged):
                setMarkedText(text, cursor: cursor, emphasis: emphasis, client: client)
                let effective = staged < 0 ? text.count : min(max(staged, 0), text.count)
                engineContext.stagedText = String(text.prefix(effective))
            case .updateCandidates(let candidates, let anchorAt, let initialHighlight, let configure):
                var cfg = engine.candidateWindowConfiguration
                configure?(&cfg)
                updateCandidates(candidates, anchorAt: anchorAt,
                                 initialHighlight: initialHighlight,
                                 configuration: cfg, client: client)
            case .commit(let candidate):
                // Engine-driven commit: no specific candidate-list index.
                candidateConfirmed(candidate.text, absoluteIndex: -1, raw: candidate)
            case .commitSelectedCandidate:
                CandidateWindow.shared.commitSelectedCandidate()
            case .commitCandidateAtIndex(let index):
                CandidateWindow.shared.commitCandidate(at: index)
            case .navigateCandidates(let direction, let wrapping):
                CandidateWindow.shared.handleNavigation(direction: direction, wrapping: wrapping)
            case .resetContext:
                endComposition(client: client)
            case .flushStaged(let append):
                endComposition(client: client, insert: engineContext.stagedText + append)
            case .enterAssociatedMode(let heldChar, let candidates):
                // Clear any leftover composing state from the emitting engine
                // (e.g. composingBuffer that produced this committed char).
                engineContext.reset()
                // reset() clears isAssociating, so set it after.
                engineContext.isAssociating = true
                executeActions([
                    .updateMarkedText(heldChar, staged: -1),
                    .updateCandidates(candidates, anchorAt: 1, initialHighlight: -1)
                ], client: client)
            }
        }
    }

    // MARK: - Marked Text

    private func setMarkedText(
        _ text: String, cursor: Int? = nil, emphasis: Range<Int>? = nil, client: IMKTextInput
    ) {
        engineContext.markedText = text
        let charIndex = cursor ?? text.count
        let cursorPosition = text.prefix(charIndex).utf16.count
        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0
            ]
        )
        if let emphasis, !emphasis.isEmpty {
            let utf16Start = text.prefix(emphasis.lowerBound).utf16.count
            let utf16End = text.prefix(emphasis.upperBound).utf16.count
            attr.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.thick.rawValue,
                range: NSRange(location: utf16Start, length: utf16End - utf16Start)
            )
        }
        client.setMarkedText(
            attr,
            selectionRange: NSRange(location: cursorPosition, length: 0),
            replacementRange: .notFound
        )
    }


    // MARK: - Candidate Window

    private func showCandidateWindow(anchorAt: Int, client: IMKTextInput) {
        let text = engineContext.markedText
        guard !text.isEmpty else { return }
        let length = text.count
        let fontKey = NSAttributedString.Key.font.rawValue

        var lineHeightRect = NSRect.zero
        var attrs: [AnyHashable: Any]?
        if anchorAt < length {
            // anchorAt maps to the start of a real character; query directly.
            let utf16Idx = text.prefix(anchorAt).utf16.count
            attrs = client.attributes(forCharacterIndex: utf16Idx, lineHeightRectangle: &lineHeightRect)
            if lineHeightRect.origin == .zero {
                attrs = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
            }
        } else {
            // anchorAt == length (past end): simulate by querying the last
            // character's rect and shifting x by its width. Avoids the cache
            // poisoning caused by querying utf16 index == length directly.
            let lastUtf16 = text.prefix(length - 1).utf16.count
            attrs = client.attributes(forCharacterIndex: lastUtf16, lineHeightRectangle: &lineHeightRect)
            let font = (attrs?[fontKey] as? NSFont)
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let lastChar = String(text.suffix(1))
            lineHeightRect.origin.x += lastChar.size(withAttributes: [.font: font]).width
        }

        var startRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &startRect)
        CandidateWindow.shared.compositionStartX = startRect.origin != .zero
            ? startRect.minX : lineHeightRect.minX

        let font = attrs?[fontKey] as? NSFont
        let compositionText = text
        let utf16Count = compositionText.utf16.count
        let startX = CandidateWindow.shared.compositionStartX

        if anchorAt < length {
            // Existing provider: lazily compute the marked-text end x.
            CandidateWindow.shared.setCompositionEndXProvider { [weak client] in
                guard let client, let font else { return startX }
                guard utf16Count >= 2 else {
                    return startX + compositionText.size(withAttributes: [.font: font]).width
                }
                let lastCharStart = compositionText.index(before: compositionText.endIndex)
                let lastIndex = compositionText.utf16.distance(
                    from: compositionText.startIndex, to: lastCharStart)
                var lastRect = NSRect.zero
                _ = client.attributes(forCharacterIndex: lastIndex, lineHeightRectangle: &lastRect)
                guard lastRect.origin != .zero else { return startX }
                let lastChar = String(compositionText[lastCharStart...])
                return lastRect.minX + lastChar.size(withAttributes: [.font: font]).width
            }
        } else {
            // anchorAt == length: lineHeightRect.origin.x is already the end x,
            // so the provider just returns the precomputed value.
            let endX = lineHeightRect.origin.x
            CandidateWindow.shared.setCompositionEndXProvider { endX }
        }

        CandidateWindow.shared.show(near: lineHeightRect)
    }

    private func hideCandidateWindow() {
        CandidateWindow.shared.hide()
    }

    private func updateCandidates(
        _ candidates: [Candidate], anchorAt: Int, initialHighlight: Int,
        configuration: CandidateWindowConfiguration?, client: IMKTextInput
    ) {
        guard !candidates.isEmpty else {
            hideCandidateWindow()
            return
        }
        CandidateWindow.shared.updateCandidates(candidates,
                                                initialHighlight: initialHighlight,
                                                configuration: configuration)
        showCandidateWindow(anchorAt: anchorAt, client: client)
    }
}

// MARK: - CandidateWindowDelegate

extension InputController: CandidateWindowDelegate {
    func candidateConfirmed(_ candidate: String, absoluteIndex: Int, raw: Candidate?) {
        guard let client = client() else { return }
        let actions = engine.candidateConfirmed(
            context: engineContext, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: currentCandidateWindowState())
        executeActions(actions, client: client)
    }

    func candidateSelectionChanged(_ candidate: String, absoluteIndex: Int, raw: Candidate) {
        guard let client = client() else { return }
        let actions = engine.candidateSelectionChanged(
            context: engineContext, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: currentCandidateWindowState())
        executeActions(actions, client: client)
    }
}

private extension InputController {
    func currentCandidateWindowState() -> CandidateWindowState {
        CandidateWindowState(
            isVisible: CandidateWindow.shared.isVisible,
            configuration: CandidateWindow.shared.currentConfiguration)
    }

    /// Policy-gated candidate-window dispatch. Returns true if the key
    /// was consumed. No-op when the window is hidden.
    func dispatchCandidateWindowKey(_ keyEvent: KeyEventInput) -> Bool {
        guard CandidateWindow.shared.isVisible else { return false }
        let cfg = CandidateWindow.shared.currentConfiguration
        let pureMods = keyEvent.modifiers.intersection(.deviceIndependentFlagsMask)
        if !pureMods.intersection([.command, .control]).isEmpty { return false }

        if cfg.handleIndexLabelKeys, !pureMods.contains(.option),
           let text = keyEvent.characters, text.count == 1, let char = text.first,
           let index = cfg.candidateIndex(for: char) {
            CandidateWindow.shared.commitCandidate(at: index)
            return true
        }
        if cfg.handleNavigationKeys {
            if let intent = cfg.navigationIntent(
                keyCode: keyEvent.keyCode,
                shift: pureMods.contains(.shift),
                option: pureMods.contains(.option)
            ) {
                CandidateWindow.shared.handleNavigation(
                    direction: intent.direction, wrapping: intent.wrapping)
                return true
            }
            if keyEvent.keyCode == 36 {  // Enter
                CandidateWindow.shared.commitSelectedCandidate()
                return true
            }
        }
        return false
    }
}
