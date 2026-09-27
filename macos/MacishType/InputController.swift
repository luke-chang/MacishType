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
    private var noPositionReported = false

    // Dispatch routes for the toggle items built by the latest `menu()`,
    // indexed by the item's tag. The tag (a plain Int) survives whatever
    // marshaling IMKit applies to menu items, which `representedObject`
    // does not guarantee, so the (kind, key) pair rides in this side
    // table instead.
    private var menuToggles: [(kind: InputEngine.MenuToggleKind, key: String)] = []

    // Built fresh each call so per-engine items and their checkmark state
    // reflect the active engine. The engine owns the section's arrangement
    // (via menuItems()); this method only renders descriptors and pins the
    // app-level items at the bottom.
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        // Auto-enablement would override engine items' explicit isEnabled.
        menu.autoenablesItems = false

        menuToggles.removeAll()
        for descriptor in engine?.menuItems() ?? [] {
            switch descriptor {
            case .divider:
                addSeparatorIfNeeded(menu)
            case .toggle(let toggle):
                let item = NSMenuItem(
                    title: toggle.title,
                    action: #selector(toggleMenuItem(_:)),
                    keyEquivalent: toggle.keyEquivalent
                )
                item.keyEquivalentModifierMask = toggle.modifiers
                item.target = self
                item.state = toggle.isOn ? .on : .off
                item.isEnabled = toggle.isEnabled
                item.tag = menuToggles.count
                menuToggles.append((toggle.kind, toggle.key))
                menu.addItem(item)
            case .command(let command):
                let item = NSMenuItem(
                    title: command.title,
                    action: Self.selector(for: command.id),
                    keyEquivalent: command.keyEquivalent
                )
                item.keyEquivalentModifierMask = command.modifiers
                item.target = self
                menu.addItem(item)
            }
        }
        addSeparatorIfNeeded(menu)

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: String(localized: "About MacishType"),
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        return menu
    }

    /// Skips the separator when the menu is empty or already ends with
    /// one, so engine dividers and section boundaries never stack.
    private func addSeparatorIfNeeded(_ menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
    }

    private static func selector(for id: InputEngine.MenuCommandID) -> Selector {
        switch id {
        case .reverseLookup: return #selector(showCodeLookup(_:))
        }
    }

    @objc private func toggleMenuItem(_ sender: Any?) {
        guard let item = Self.commandMenuItem(from: sender),
              menuToggles.indices.contains(item.tag) else { return }
        let toggle = menuToggles[item.tag]
        engine?.toggleMenuItem(kind: toggle.kind, key: toggle.key)
    }

    /// IMKit dispatches menu-item actions with the command infoDictionary as
    /// the sender — {kIMKCommandMenuItemName: the selected NSMenuItem,
    /// kIMKCommandClientName: the client} — not the NSMenuItem itself.
    private static func commandMenuItem(from sender: Any?) -> NSMenuItem? {
        if let item = sender as? NSMenuItem { return item }
        return (sender as? NSDictionary)?[kIMKCommandMenuItemName] as? NSMenuItem
    }

    @MainActor override func showPreferences(_ sender: Any!) {
        let initialID = engine?.engineID
        WindowManager.shared.openSettings(initialEngineID: initialID)
    }

    @MainActor @objc private func showAboutWindow(_ sender: Any?) {
        WindowManager.shared.openAbout()
    }

    /// Reads the selection BEFORE opening the window: WindowManager's
    /// NSApp.activate() steals the client's focus, after which the client's
    /// selection is no longer readable.
    @MainActor @objc private func showCodeLookup(_ sender: Any?) {
        WindowManager.shared.openCodeLookup(
            seedText: selectedClientText(), initialEngineID: engine?.engineID)
    }

    /// The client's current selection; nil when there is none or the client
    /// can't report it. Clients without TSMDocumentAccess return
    /// {NSNotFound, NSNotFound}, and NSNotFound is NSIntegerMax — a bare
    /// `length > 0` check would pass, so both fields need explicit guards.
    private func selectedClientText() -> String? {
        guard let client = client() else { return nil }
        var range = client.selectedRange()
        guard range.location != NSNotFound, range.length != NSNotFound, range.length > 0
        else { return nil }
        // Cap absurd selections (select-all in a huge document).
        let wasCapped = range.length > 256
        range.length = min(range.length, 256)
        guard var text = client.attributedSubstring(from: range)?.string else { return nil }
        // A capped range can bisect a surrogate pair; the lone high surrogate
        // bridges into Swift as U+FFFD. Drop it so the seed ends on a whole
        // character.
        if wasCapped, text.hasSuffix("\u{FFFD}") {
            text.removeLast()
        }
        return text
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
        Logger.inputController.debug("deactivateEngine ctrl=\("\(ObjectIdentifier(self))", privacy: .public) engine=\("\(type(of: engine))", privacy: .public) activated=\(engineContext.isActivated, privacy: .public)")
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
                let output = engine?.transformCommittedText(insertion) ?? insertion
                client.insertText(output, replacementRange: .notFound)
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
        noPositionReported = false
        hideCandidateWindow()
        applyKeyboardLayoutOverride(sender)
    }

    private static let overrideKeyboardSel = NSSelectorFromString("overrideKeyboardWithKeyboardNamed:")

    /// Pin the layout the IM reads keys with, per the General setting (empty =
    /// follow the system). Re-applied each activation since the override is
    /// per-session. Sent by selector as `overrideKeyboardWithKeyboardNamed:`
    /// isn't surfaced in Swift; a stale (uninstalled) ID silently no-ops.
    private func applyKeyboardLayoutOverride(_ sender: Any!) {
        let layoutID = UserDefaults.standard.string(forKey: KeyboardLayouts.overrideDefaultsKey) ?? ""
        guard !layoutID.isEmpty,
              let client = sender as AnyObject?,
              client.responds(to: Self.overrideKeyboardSel) else { return }
        _ = client.perform(Self.overrideKeyboardSel, with: layoutID)
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
        Logger.inputController.debug("commitComposition ctrl=\("\(ObjectIdentifier(self))", privacy: .public) client=\(clientID, privacy: .public)")
        #endif
        endComposition(client: sender as? IMKTextInput, insert: engineContext?.stagedText)
        if let engineContext { engine?.compositionCommitted(context: engineContext) }
    }

    // MARK: - Event Handling

    /// keyDown plus flagsChanged — the latter only feeds the Shift-gated
    /// digit labels and is never consumed.
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // Before anything touches `characters` — NSEvent raises on non-key
        // events.
        if event.type == .flagsChanged {
            CandidateWindow.shared.shiftHeld = event.modifierFlags.contains(.shift)
            return false
        }
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
        // Caps Lock stays in: the answer should be the character this key would
        // type without Option, which is what the full-width commit converts.
        let casingOnly = event.modifierFlags.intersection([.shift, .capsLock])
        let charactersIgnoringModifiers = event.characters(byApplyingModifiers: casingOnly)
        let keyEvent = KeyEventInput(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            isRepeat: event.isARepeat)
        // Tier 1a: policy-gated candidate-window key handling
        if dispatchCandidateWindowKey(keyEvent) {
            return true
        }
        if engineContext.isAssociating {
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
        } else {
            // Tier 1b: while a composition is in progress, let the engine commit
            // the staged text and re-dispatch this key on a fresh context.
            if !engineContext.markedText.isEmpty,
               engine.shouldFlushStagedBeforeHandling(
                   context: engineContext, keyEvent: keyEvent,
                   candidateWindow: candidateWindowState) {
                executeActions([.flushStaged()], client: client)
                // falls through to engine.handleKey on the reset context
            }
        }
        // A preceding tier may have flushed (hiding the window and resetting the
        // context), so re-query the window state for handleKey.
        let result = engine.handleKey(
            context: engineContext,
            keyEvent: keyEvent,
            candidateWindow: currentCandidateWindowState())
        executeActions(result.actions, client: client)
        return result.isHandled
    }

    // MARK: - Action Executor

    private func executeActions(_ actions: [EngineAction], client: IMKTextInput) {
        for action in actions {
            switch action {
            case .updateMarkedText(let text, let cursor, let emphasis, let staged):
                setMarkedText(text, cursor: cursor, emphasis: emphasis, client: client)
                let effective = staged < 0 ? text.count : Self.clampIndex(staged, to: text.count)
                engineContext.stagedText = String(text.prefix(effective))
            case .updateCandidates(let candidates, let anchorAt, let initialHighlight, let configure):
                // Associated mode rebases every update on the session snapshot,
                // so engine-driven refreshes keep the policy window.
                var cfg = engineContext.isAssociating
                    ? engine.associatedCandidateWindowConfiguration
                    : engine.candidateWindowConfiguration
                configure?(&cfg)
                updateCandidates(candidates, anchorAt: anchorAt,
                                 initialHighlight: initialHighlight,
                                 configuration: cfg, client: client)
            case .updateMessage(let text, let anchorAt, let duration):
                updateMessage(text, anchorAt: anchorAt, duration: duration, client: client)
            case .commit(let candidate):
                // Engine-driven commit: no specific candidate-list index.
                candidateConfirmed(candidate.text, absoluteIndex: -1, raw: candidate)
            case .commitSelectedCandidate:
                CandidateWindow.shared.commitSelectedCandidate()
            case .commitCandidateAtIndex(let index):
                // An index the engine names past the page's last candidate is
                // a no-op with no fallback.
                _ = CandidateWindow.shared.commitCandidate(at: index)
            case .navigateCandidates(let direction, let wrapping):
                CandidateWindow.shared.handleNavigation(direction: direction, wrapping: wrapping)
            case .resetContext:
                endComposition(client: client)
            case .flushStaged(let append):
                endComposition(client: client, insert: engineContext.stagedText + append)
            case .enterAssociatedMode(let heldText, let candidates):
                // The held text is what keeps the composition alive under the
                // follow-ups; with none there is no mode to enter. Say so, then
                // take the empty-list exit.
                if heldText.isEmpty, !candidates.isEmpty {
                    Logger.inputController.notice(
                        "enterAssociatedMode with an empty held text: \(candidates.count, privacy: .public) follow-ups dropped, composition ended")
                }
                // No follow-ups: commit what has accumulated rather than leave a
                // preedit under a hidden window. Not .flushStaged — heldText
                // already includes stagedText, which flushStaged would prepend
                // a second time.
                if heldText.isEmpty || candidates.isEmpty {
                    endComposition(client: client, insert: heldText)
                    break
                }
                // Clear any leftover composing state from the emitting engine
                // (e.g. composingBuffer that produced this committed char).
                engineContext.reset()
                // reset() clears isAssociating, so set it after — the
                // updateCandidates below rebases on it.
                engineContext.isAssociating = true
                executeActions([
                    .updateMarkedText(heldText, staged: -1),
                    .updateCandidates(candidates, anchorAt: heldText.count, initialHighlight: -1)
                ], client: client)
            case .beep:
                AlertSound.play()
            }
        }
    }

    // MARK: - Marked Text

    /// Engine indices arrive unchecked, and `String.prefix` traps on a
    /// negative count. Clamp to `0...length` like the other hosts.
    private static func clampIndex(_ index: Int, to length: Int) -> Int {
        min(max(index, 0), length)
    }

    private func setMarkedText(
        _ text: String, cursor: Int? = nil, emphasis: Range<Int>? = nil, client: IMKTextInput
    ) {
        // Substitution is 1-for-1, so character-based cursor/emphasis stay valid.
        let display = Self.displayableMarkedText(text)
        engineContext.markedText = display
        let length = display.count
        let charIndex = Self.clampIndex(cursor ?? length, to: length)
        let cursorPosition = display.prefix(charIndex).utf16.count
        let attr = NSMutableAttributedString(
            string: display,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0
            ]
        )
        if let emphasis = emphasis?.clamped(to: 0..<length), !emphasis.isEmpty {
            let utf16Start = display.prefix(emphasis.lowerBound).utf16.count
            let utf16End = display.prefix(emphasis.upperBound).utf16.count
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

    /// Substitute characters this Mac can't render with a placeholder: some
    /// clients freeze their marked-text layout once they draw a LastResort
    /// glyph. The real character still reaches the candidate window and the
    /// committed text. Coverage matches the candidate filter (`FontCoverage`).
    private static func displayableMarkedText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        var substituted = false
        for character in text {
            if FontCoverage.shared.classify(String(character)) == .none {
                result.append("\u{FFFD}")
                substituted = true
            } else {
                result.append(character)
            }
        }
        return substituted ? result : text
    }


    // MARK: - Candidate Window

    /// Window geometry measured before a candidate update reaches the window:
    /// applying it can run a selection hook that rewrites marked text.
    private struct CandidateAnchor {
        let nearRect: NSRect
        let startX: CGFloat
        let font: NSFont?
    }

    /// A zero `nearRect` (the client reported no position) still shows the
    /// window, at the screen's fallback corner: a misplaced list still takes
    /// a selection.
    private func measureCandidateAnchor(anchorAt: Int, client: IMKTextInput) -> CandidateAnchor {
        let text = engineContext.markedText
        let length = text.count
        let index = Self.clampIndex(anchorAt, to: length)
        let fontKey = NSAttributedString.Key.font.rawValue

        var lineHeightRect = NSRect.zero
        var attrs: [AnyHashable: Any]?
        if index == length, length > 0 {
            // Past the end: simulate by querying the last character's rect and
            // shifting x by its width. Avoids the cache poisoning caused by
            // querying utf16 index == length directly.
            let lastUtf16 = text.prefix(length - 1).utf16.count
            attrs = client.attributes(forCharacterIndex: lastUtf16, lineHeightRectangle: &lineHeightRect)
            if lineHeightRect.origin != .zero {
                let font = (attrs?[fontKey] as? NSFont)
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let lastChar = String(text.suffix(1))
                lineHeightRect.origin.x += lastChar.size(withAttributes: [.font: font]).width
            }
        } else {
            // Index 0 with no composition is past the end too, but with no
            // session there is no cache to poison; clients answer with the
            // live insertion point.
            let utf16Idx = text.prefix(index).utf16.count
            attrs = client.attributes(forCharacterIndex: utf16Idx, lineHeightRectangle: &lineHeightRect)
        }

        var startRect = NSRect.zero
        var startAttrs: [AnyHashable: Any]?
        if length > 0 {
            startAttrs = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &startRect)
        }
        if lineHeightRect.origin == .zero {
            lineHeightRect = startRect
            attrs = startAttrs ?? attrs
        }
        if lineHeightRect.origin == .zero, !noPositionReported {
            noPositionReported = true
            Logger.inputController.notice(
                "client reported no position for the candidate window; showing it at the fallback location")
        }
        return CandidateAnchor(
            nearRect: lineHeightRect,
            startX: startRect.origin != .zero ? startRect.minX : lineHeightRect.minX,
            font: attrs?[fontKey] as? NSFont
        )
    }

    private func applyCandidateAnchor(_ anchor: CandidateAnchor, client: IMKTextInput) {
        let startX = anchor.startX
        let font = anchor.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        CandidateWindow.shared.compositionStartX = startX

        // Lazy because each queried index freezes in the client's position
        // cache. Resolved at call time rather than captured — navigation
        // rewrites marked text without going through updateCandidates, so a
        // snapshot would query past the end of the live composition.
        CandidateWindow.shared.setCompositionEndXProvider { [weak self, weak client] in
            guard let self, let client else { return startX }
            let text = self.engineContext.markedText
            guard !text.isEmpty else { return startX }
            guard text.utf16.count >= 2 else {
                return startX + text.size(withAttributes: [.font: font]).width
            }
            let lastCharStart = text.index(before: text.endIndex)
            let lastIndex = text.utf16.distance(from: text.startIndex, to: lastCharStart)
            var lastRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: lastIndex, lineHeightRectangle: &lastRect)
            guard lastRect.origin != .zero else { return startX }
            let lastChar = String(text[lastCharStart...])
            return lastRect.minX + lastChar.size(withAttributes: [.font: font]).width
        }

        CandidateWindow.shared.show(near: anchor.nearRect)
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
        anchored(anchorAt: anchorAt, client: client) {
            CandidateWindow.shared.updateCandidates(candidates,
                                                    initialHighlight: initialHighlight,
                                                    configuration: configuration)
        }
    }

    private func updateMessage(_ text: String, anchorAt: Int, duration: Int,
                               client: IMKTextInput) {
        // Dismissal takes no anchor: measuring one would end in a reposition
        // that orders the just-hidden panel back on screen.
        guard !text.isEmpty else {
            CandidateWindow.shared.updateMessage("")
            return
        }
        anchored(anchorAt: anchorAt, client: client) {
            CandidateWindow.shared.updateMessage(text, duration: duration)
        }
    }

    /// Runs a window update between an anchor measurement and the reposition
    /// it feeds. Applying an update fires candidateSelectionChanged
    /// synchronously and that hook may rewrite marked text, while `anchorAt`
    /// indexes the text as it is now. A hook that hides the window — ending
    /// the composition does — must not see it shown again.
    private func anchored(anchorAt: Int, client: IMKTextInput, _ update: () -> Void) {
        let hides = CandidateWindow.shared.hideCount
        let anchor = measureCandidateAnchor(anchorAt: anchorAt, client: client)
        update()
        if CandidateWindow.shared.hideCount != hides { return }
        applyCandidateAnchor(anchor, client: client)
    }
}

// MARK: - CandidateWindowDelegate

extension InputController: CandidateWindowDelegate {
    func candidateConfirmed(_ candidate: String, absoluteIndex: Int, raw: Candidate?) {
        guard let client = client() else { return }
        let result = engine.candidateConfirmed(
            context: engineContext, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: currentCandidateWindowState())
        // The engine's actions land first: the fallback layers on top of them and
        // reads context / window state afterwards.
        executeActions(result.actions, client: client)
        guard !result.isHandled else { return }
        executeActions(engine.candidateConfirmedFallback(
            context: engineContext, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: currentCandidateWindowState()), client: client)
    }

    func candidateSelectionChanged(_ candidate: String, absoluteIndex: Int, raw: Candidate) {
        guard let client = client() else { return }
        // The contract gives this the same result shape as candidateConfirmed;
        // there is no host default to fall back to yet.
        executeActions(engine.candidateSelectionChanged(
            context: engineContext, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: currentCandidateWindowState()).actions, client: client)
    }
}

private extension InputController {
    func currentCandidateWindowState() -> CandidateWindowState {
        CandidateWindowState(
            isVisible: CandidateWindow.shared.hasCandidates,
            configuration: CandidateWindow.shared.currentConfiguration,
            message: CandidateWindow.shared.messageText,
            pageRange: CandidateWindow.shared.pageRange)
    }

    /// Policy-gated candidate-window dispatch. Returns true if the key
    /// was consumed. No-op when the window is hidden.
    func dispatchCandidateWindowKey(_ keyEvent: KeyEventInput) -> Bool {
        guard CandidateWindow.shared.hasCandidates else { return false }
        let cfg = CandidateWindow.shared.currentConfiguration
        let pureMods = keyEvent.pureModifiers
        if !pureMods.intersection([.command, .control]).isEmpty { return false }

        if cfg.handleIndexLabelKeys {
            let character = keyEvent.characters.flatMap { $0.count == 1 ? $0.first : nil }
            // A label with no candidate behind it — the trailing slots of a
            // short last page — is not the host's to eat: the commit declines
            // and the key travels on to the engine like any other.
            if let index = cfg.candidateIndex(
                forWebCode: KeyboardEventMapping.webCode(for: keyEvent.keyCode),
                shift: pureMods.contains(.shift),
                option: pureMods.contains(.option), character: character),
               CandidateWindow.shared.commitCandidate(at: index) {
                return true
            }
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
            // Only an unmodified Return commits (Cmd / Ctrl already filtered
            // above). Nothing picked in associated mode means no candidate to
            // commit, so Return dismisses through the normal tiers instead.
            if keyEvent.isReturnKey,
               pureMods.intersection([.shift, .option]).isEmpty,
               !engineContext.isAssociating || CandidateWindow.shared.hasSelection {
                CandidateWindow.shared.commitSelectedCandidate()
                return true
            }
        }
        return false
    }
}
