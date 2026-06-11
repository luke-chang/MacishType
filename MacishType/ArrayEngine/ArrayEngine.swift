import SwiftUI

/// Per-session state for the Array engine, mirroring the composing / selecting /
/// symbol-group / group-menu modes.
final class ArrayEngineContext: InputEngineContext {
    var code = ""
    var selecting = false       // true = candidate-selection (Space-entered)
    var symbolGroup = false     // a symbol group: Space pages instead of committing
    var groupMenu = false       // a symbol prefix's group menu

    override func reset() {
        super.reset()
        code = ""
        selecting = false
        symbolGroup = false
        groupMenu = false
    }
}

/// Array (行列) input method.
///
/// Composing shows the radical readout as marked text and previews short codes
/// (≤2 keys) or main candidates (3+); Space resolves the code to
/// candidate-selection. Also: `'` phrase lookup, `?`/`*` wildcard query, `w`/`hg`
/// symbol groups, Option+key full-width, and `=`/`-`/`[`/`]` paging.
final class ArrayEngine: InputEngine {
    static let shared = ArrayEngine()
    override var engineID: String { "Array" }

    static let showRareCharactersSubKey = "showRareCharacters"
    private var showRareCharacters = false
    private var dictionary: ArrayDictionary?

    override func createContext() -> InputEngineContext { ArrayEngineContext() }

    override func reloadConfig() {
        super.reloadConfig()
        let key = Self.composedKey(engineID: engineID, subKey: Self.showRareCharactersSubKey)
        let value = (UserDefaults.standard.object(forKey: key) as? Bool) ?? false
        if value != showRareCharacters {
            showRareCharacters = value
            dictionary?.reloadRareTables(includeRare: value)
        }
    }

    override func load() {
        if dictionary == nil {
            dictionary = ArrayDictionary(
                locale: intendedLanguage ?? "zh-Hant", includeRare: showRareCharacters)
        }
        super.load()
    }

    override func unload() {
        dictionary = nil
        super.unload()
    }

    override var candidateWindowConfiguration: CandidateWindowConfiguration {
        var configuration = super.candidateWindowConfiguration
        configuration.indexLabels = "1234567890"
        configuration.pageSize = 10
        configuration.expandable = false
        return configuration
    }

    override var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engine: self)
                Section("Typing") {
                    InputEngine.EnableAssociatedModeToggle(engine: self)
                    ArrayRareToggle(engine: self)
                }
            }
        )
    }

    // MARK: - Key Handling

    override func handleKey(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        guard let dictionary else { return .notHandled() }
        let ctx = context as! ArrayEngineContext

        if !ctx.code.isEmpty {
            if ArrayDictionary.hasWildcard(ctx.code) {
                return handleWildcardKey(ctx, keyEvent, candidateWindow, dictionary)
            }
            return ctx.selecting
                ? handleSelectingKey(ctx, keyEvent, candidateWindow, dictionary)
                : handleComposingKey(ctx, keyEvent, candidateWindow, dictionary)
        }

        // Idle: a composition / wildcard key starts a new code; Option+printable
        // commits its full-width form; everything else passes to the OS.
        if let key = compositionChar(keyEvent) {
            ctx.code = String(key)
            return .handled(renderActions(ctx, dictionary))
        }
        if let key = wildcardChar(keyEvent) {
            ctx.code = String(key)
            return .handled(renderWildcardActions(ctx, dictionary))
        }
        let mods = keyEvent.pureModifiers
        if mods.contains(.option), mods.intersection([.command, .control]).isEmpty,
           let chars = keyEvent.charactersIgnoringModifiers, chars.count == 1,
           let char = chars.first, let fullwidth = Self.toFullwidth(char) {
            return .handled([.flushStaged(String(fullwidth))])
        }
        return .notHandled()
    }

    /// Selecting-mode: a composition key commits the highlighted candidate, then
    /// the host re-dispatches the key to start a fresh composition.
    override func shouldFlushStagedBeforeHandling(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> Bool {
        let ctx = context as! ArrayEngineContext
        return ctx.selecting && compositionChar(keyEvent) != nil
    }

    /// Page the associated-candidate window with the same keys as elsewhere;
    /// other keys fall through to the base (dismiss + re-dispatch).
    override func handleAssociatedKey(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        if let page = pageAction(keyEvent, candidateWindow) { return .handled([page]) }
        return super.handleAssociatedKey(
            context: context, keyEvent: keyEvent, candidateWindow: candidateWindow)
    }

    private func handleComposingKey(
        _ ctx: ArrayEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ dictionary: ArrayDictionary
    ) -> EngineHandleResult {
        if let page = pageAction(event, window) { return .handled([page]) }
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                ctx.code = String(ctx.code.dropLast())
                return ctx.code.isEmpty ? .handled([.resetContext]) : .handled(renderActions(ctx, dictionary))
            case KeyCode.space:
                return .handled(enterSelecting(ctx, dictionary.main(ctx.code)))
            case KeyCode.quote:
                return .handled(enterSelecting(ctx, dictionary.phrase(ctx.code)))
            default:
                break
            }
        }
        if let key = wildcardChar(event), canExtendWildcard(ctx) {
            ctx.code.append(key)
            return .handled(renderWildcardActions(ctx, dictionary))
        }
        if let key = compositionChar(event), canExtend(ctx, key) {
            ctx.code.append(key)
            return .handled(renderActions(ctx, dictionary))
        }
        return .handled([])
    }

    private func handleSelectingKey(
        _ ctx: ArrayEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ dictionary: ArrayDictionary
    ) -> EngineHandleResult {
        if let page = pageAction(event, window) { return .handled([page]) }
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                // Step back one stage: a symbol group returns to its prefix menu,
                // a candidate list returns to the composing preview of the code.
                if ctx.symbolGroup { ctx.code = String(ctx.code.dropLast()) }
                ctx.selecting = false
                ctx.symbolGroup = false
                return ctx.code.isEmpty
                    ? .handled([.resetContext])
                    : .handled(renderActions(ctx, dictionary))
            case KeyCode.space:
                return ctx.symbolGroup
                    ? .handled([.navigateCandidates(.pageForward, wrapping: true)])
                    : .handled([.commitSelectedCandidate])
            default:
                break
            }
        }
        // Composition keys are handled by shouldFlushStagedBeforeHandling;
        // anything else is swallowed while composing.
        return .handled([])
    }

    private func handleWildcardKey(
        _ ctx: ArrayEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ dictionary: ArrayDictionary
    ) -> EngineHandleResult {
        if let page = pageAction(event, window) { return .handled([page]) }
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                ctx.code = String(ctx.code.dropLast())
                if ctx.code.isEmpty { return .handled([.resetContext]) }
                return ArrayDictionary.hasWildcard(ctx.code)
                    ? .handled(renderWildcardActions(ctx, dictionary))
                    : .handled(renderActions(ctx, dictionary))
            case KeyCode.space:
                return .handled([.navigateCandidates(.pageForward, wrapping: true)])
            default:
                break
            }
        }
        if let key = compositionChar(event) ?? wildcardChar(event), canExtendWildcard(ctx) {
            ctx.code.append(key)
            return .handled(renderWildcardActions(ctx, dictionary))
        }
        return .handled([])
    }

    override func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int,
        raw: Candidate?, candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        let ctx = context as! ArrayEngineContext
        if ctx.groupMenu {
            // Group menu: open the picked group (its code is the candidate payload).
            if let groupCode = raw?.payload as? String {
                ctx.code = groupCode
                return enterSymbolGroup(ctx, dictionary?.symbolGroup(groupCode) ?? [])
            }
            return []
        }
        // Clear the staged preview so the host commits exactly this candidate;
        // in associated mode keep the staged held char for the follow-up.
        let prefix: [EngineAction] = context.isAssociating ? [] : [.updateMarkedText("")]
        return prefix + super.candidateConfirmed(
            context: context, candidate, absoluteIndex: absoluteIndex,
            raw: raw, candidateWindow: candidateWindow)
    }

    override func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int,
        raw: Candidate, candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        let ctx = context as! ArrayEngineContext
        return ctx.selecting ? [.updateMarkedText(candidate, staged: -1)] : []
    }

    // MARK: - Rendering

    /// Composing preview: marked text is the radical readout; the window shows a
    /// group menu (symbol prefix), short codes (≤2 keys), or main candidates (3+).
    private func renderActions(_ ctx: ArrayEngineContext, _ dictionary: ArrayDictionary) -> [EngineAction] {
        ctx.groupMenu = false
        var actions: [EngineAction] = [.updateMarkedText(dictionary.radicalReadout(ctx.code))]
        if ctx.code.count <= 2 {
            if dictionary.isSymbolPrefix(ctx.code) {
                return actions + showGroupMenu(ctx, dictionary)
            }
            let view = dictionary.shortCodeView(ctx.code)
            let spaceTarget = dictionary.main(ctx.code).first
            let highlight = spaceTarget.flatMap { view.candidates.firstIndex(of: $0) } ?? -1
            actions.append(.updateCandidates(
                view.candidates.map { Candidate($0) },
                initialHighlight: highlight,
                configure: { $0.indexLabels = view.indexLabels }))
        } else {
            // An empty list (a prefix en route to a longer code) hides the window.
            actions.append(.updateCandidates(dictionary.main(ctx.code).map { Candidate($0) }))
        }
        return actions
    }

    private func renderWildcardActions(_ ctx: ArrayEngineContext, _ dictionary: ArrayDictionary) -> [EngineAction] {
        [.updateMarkedText(dictionary.radicalReadout(ctx.code)),
         .updateCandidates(dictionary.wildcardMatches(ctx.code),
                           configure: { $0.layoutDirection = .vertical })]
    }

    /// Vertical menu of a symbol prefix's groups, each labeled by its digit, no
    /// default highlight. Picking one opens it (the group code is the payload).
    private func showGroupMenu(_ ctx: ArrayEngineContext, _ dictionary: ArrayDictionary) -> [EngineAction] {
        ctx.groupMenu = true
        var candidates: [Candidate] = []
        var indexLabels = ""
        for digit in ArrayDictionary.selectionKeys {
            let groupCode = ctx.code + String(digit)
            guard dictionary.hasSymbolGroup(groupCode) else { continue }
            candidates.append(Candidate(
                ArrayDictionary.groupNames[groupCode] ?? "符號組", payload: groupCode))
            indexLabels.append(digit)
        }
        return [.updateCandidates(candidates, initialHighlight: -1, configure: {
            $0.indexLabels = indexLabels
            $0.layoutDirection = .vertical
        })]
    }

    /// A symbol group: candidate-selection over the group's symbols, annotated
    /// with their names and laid out vertically.
    private func enterSymbolGroup(_ ctx: ArrayEngineContext, _ symbols: [String]) -> [EngineAction] {
        guard !symbols.isEmpty else { return [.resetContext] }
        ctx.selecting = true
        ctx.symbolGroup = true
        ctx.groupMenu = false
        return [.updateMarkedText(symbols[0], staged: -1),
                .updateCandidates(
                    symbols.map { Candidate($0, annotation: dictionary?.symbolName($0)) },
                    initialHighlight: 0,
                    configure: { $0.layoutDirection = .vertical })]
    }

    /// Resolve `candidates` (main or phrase) and enter candidate-selection. A
    /// single candidate commits through `.commit` so the host can enter
    /// associated mode for it.
    private func enterSelecting(_ ctx: ArrayEngineContext, _ candidates: [String]) -> [EngineAction] {
        ctx.groupMenu = false
        if candidates.isEmpty {
            return [.resetContext]
        } else if candidates.count == 1 {
            return [.commit(Candidate(candidates[0]))]
        } else {
            ctx.selecting = true
            ctx.symbolGroup = false
            return [.updateMarkedText(candidates[0], staged: -1),
                    .updateCandidates(candidates.map { Candidate($0) }, initialHighlight: 0)]
        }
    }

    // MARK: - Helpers

    /// Paging keys, active whenever the candidate window is visible: `=`/`]` or
    /// Shift+→ page forward, `-`/`[` or Shift+← page back (no wrap).
    private func pageAction(_ event: KeyEventInput, _ window: CandidateWindowState) -> EngineAction? {
        guard window.isVisible,
              event.pureModifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let shift = event.pureModifiers.contains(.shift)
        switch (event.keyCode, shift) {
        case (KeyCode.equal, false), (KeyCode.rightBracket, false), (KeyCode.rightArrow, true):
            return .navigateCandidates(.pageForward)
        case (KeyCode.minus, false), (KeyCode.leftBracket, false), (KeyCode.leftArrow, true):
            return .navigateCandidates(.pageBackward)
        default:
            return nil
        }
    }

    /// The Array key at `event`'s physical position; layout-independent. Routes
    /// the keyCode through the shared keyCode → W3C-position map.
    private func compositionChar(_ event: KeyEventInput) -> Character? {
        guard event.isBareKey else { return nil }
        return ArrayDictionary.arrayKey(forWebCode: KeyboardEventMapping.webCode(for: event.keyCode))
    }

    /// The typed wildcard symbol (`?` / `*`) — by character, not position, so it
    /// follows the layout. Shift is allowed (both are shifted on US QWERTY).
    private func wildcardChar(_ event: KeyEventInput) -> Character? {
        guard event.pureModifiers.intersection([.command, .control, .option]).isEmpty,
              let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let char = chars.first, char == "?" || char == "*" else { return nil }
        return char
    }

    /// Whether `key` may extend the code: capped at `maxCodeLength`, and the 5th
    /// key may only be the disambiguation key.
    private func canExtend(_ ctx: ArrayEngineContext, _ key: Character) -> Bool {
        if ctx.code.count >= ArrayDictionary.maxCodeLength { return false }
        if ctx.code.count == ArrayDictionary.maxCodeLength - 1
            && key != ArrayDictionary.disambiguationKey { return false }
        return true
    }

    private func canExtendWildcard(_ ctx: ArrayEngineContext) -> Bool {
        ctx.code.count < ArrayDictionary.maxCodeLength
    }
}

/// Toggle for showing rare characters (those without a bundled-font glyph).
private struct ArrayRareToggle: View {
    @AppStorage private var value: Bool

    init(engine: InputEngine) {
        self._value = AppStorage(
            wrappedValue: false,
            InputEngine.composedKey(
                engineID: engine.engineID, subKey: ArrayEngine.showRareCharactersSubKey))
    }

    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show rare characters")
                Text("Requires the matching font installed to display correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
