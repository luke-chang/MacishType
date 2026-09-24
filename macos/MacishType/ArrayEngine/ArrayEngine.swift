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

    static let showShortCodePlaceholdersSubKey = "showShortCodePlaceholders"
    static let defaultShowShortCodePlaceholders = false

    /// The payload tells a placeholder apart from the same glyph in the main table.
    static let placeholderPayload = "placeholder"
    private static let placeholder = Candidate("□", payload: placeholderPayload)

    private var characterSetScope = ArrayEngine.defaultCharacterSetScope
    private var showShortCodePlaceholders = ArrayEngine.defaultShowShortCodePlaceholders
    private var dictionary: ArrayDictionary?
    private var coverageObserver: (any NSObjectProtocol)?
    private var coverageDirty = false

    override func createContext() -> InputEngineContext { ArrayEngineContext() }

    override func reloadConfig() {
        super.reloadConfig()
        showShortCodePlaceholders = defaultsValue(
            Self.showShortCodePlaceholdersSubKey, fallback: Self.defaultShowShortCodePlaceholders)
        let value: InputEngine.CharacterSetScope =
            defaultsValue(Self.characterSetScopeSubKey, fallback: Self.defaultCharacterSetScope)
        if value != characterSetScope {
            characterSetScope = value
            dictionary?.reloadTables(scope: value)
        } else if coverageDirty {
            // Font coverage changed while loaded; re-filter with the same scope.
            dictionary?.reloadTables(scope: value, force: true)
        }
        coverageDirty = false
    }

    override func load() {
        if dictionary == nil {
            dictionary = ArrayDictionary(
                locale: intendedLanguage ?? "zh-Hant", scope: characterSetScope)
        }
        if coverageObserver == nil {
            coverageObserver = NotificationCenter.default.addObserver(
                forName: FontCoverage.coverageDidChange, object: nil, queue: .main
            ) { [weak self] _ in self?.coverageDirty = true }
        }
        super.load()
    }

    override func unload() {
        if let observer = coverageObserver {
            NotificationCenter.default.removeObserver(observer)
            coverageObserver = nil
        }
        coverageDirty = false
        dictionary = nil
        super.unload()
    }

    // MARK: Reverse Lookup

    override var supportsReverseLookup: Bool { true }

    override func prepareReverseLookup() async -> Bool {
        guard !reverseLookupFailed else { return false }
        if !isLoaded {
            load()
            loadedForLookup = isLoaded
        }
        guard let dictionary else {
            reverseLookupFailed = true
            return false
        }
        dictionary.prepareReverseIndex()
        return true
    }

    override func endReverseLookup() {
        dictionary?.releaseReverseIndex()
        super.endReverseLookup()
    }

    override func reverseLookup(_ character: Character) -> [ReverseCode] {
        guard let dictionary else { return [] }
        let main = dictionary.reverseCodes(for: character).map {
            ReverseCode(dictionary.radicalReadout($0))
        }
        // Short codes render as "readout+selectionKey" — type the code, then
        // press the fixed selection key to commit.
        let short = dictionary.reverseShortCodes(for: character).map {
            ReverseCode(
                "\(dictionary.radicalReadout($0.code))+\($0.label)",
                annotation: String(localized: "Short code"))
        }
        return main + short
    }

    override var candidateWindowConfiguration: CandidateWindowConfiguration {
        var configuration = super.candidateWindowConfiguration
        configuration.indexLabels = ArrayDictionary.selectionKeyLabels
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
                    ArrayShortCodePlaceholdersToggle(engine: self)
                    InputEngine.CharacterSetScopePicker(engine: self)
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
        // The host already consumed the selection keys that address a candidate,
        // so one reaching here mid-composition is a mistype. Deliberately ahead
        // of the keypad rule below, which would otherwise swallow keypad digits;
        // the composition check keeps a layout whose digits sit on Array key
        // positions composing.
        if !ctx.code.isEmpty, Self.isSelectionKey(keyEvent), compositionChar(keyEvent) == nil {
            return .handled([.beep, .resetContext])
        }
        // Before wildcardChar: keypad `*` must not start a wildcard query.
        if let numericPad = Self.numericPadResult(for: keyEvent, context: context) {
            return numericPad
        }

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
        if let optionFullwidth = Self.hostOptionFullwidthResult(for: keyEvent, context: context) {
            return optionFullwidth
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
            case KeyCode.escape, KeyCode.keypadClear:
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
        if let key = wildcardChar(event) {
            return extendWildcard(ctx, key, dictionary)
        }
        if let key = compositionChar(event) {
            guard canExtend(ctx, key) else { return .handled([.beep]) }
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
            case KeyCode.escape, KeyCode.keypadClear:
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
            case KeyCode.escape, KeyCode.keypadClear:
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
        if let key = compositionChar(event) ?? wildcardChar(event) {
            return extendWildcard(ctx, key, dictionary)
        }
        return .handled([])
    }

    private func extendWildcard(
        _ ctx: ArrayEngineContext, _ key: Character, _ dictionary: ArrayDictionary
    ) -> EngineHandleResult {
        guard canExtendWildcard(ctx) else { return .handled([.beep]) }
        ctx.code.append(key)
        return .handled(renderWildcardActions(ctx, dictionary))
    }

    override func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int,
        raw: Candidate?, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let ctx = context as! ArrayEngineContext
        if ctx.groupMenu {
            // Group menu: open the picked group (its code is the candidate payload).
            if let groupCode = raw?.payload as? String {
                ctx.code = groupCode
                return .handled(enterSymbolGroup(ctx, dictionary?.symbolGroup(groupCode) ?? []))
            }
            return .handled()
        }
        // An empty slot selects nothing, same as a digit with no candidate.
        if raw?.payload as? String == Self.placeholderPayload {
            return .handled([.beep, .resetContext])
        }
        // Nothing highlighted: in associated mode the host commits the held
        // text; otherwise there is nothing to confirm.
        if candidate.isEmpty {
            return context.isAssociating ? .notHandled() : .handled()
        }
        return .notHandled(stagedPreviewClear(candidate, context: context))
    }

    override func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int,
        raw: Candidate, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let ctx = context as! ArrayEngineContext
        return .handled(ctx.selecting ? [.updateMarkedText(candidate, staged: -1)] : [])
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
            let view = Self.shortCodeView(
                entries: dictionary.shortCodeEntries(ctx.code),
                placeholders: showShortCodePlaceholders,
                highlighting: dictionary.main(ctx.code).first)
            actions.append(.updateCandidates(
                view.candidates,
                initialHighlight: view.highlight,
                configure: { $0.indexLabels = view.indexLabels }))
        } else {
            // An empty list (a prefix en route to a longer code) hides the window.
            actions.append(.updateCandidates(dictionary.main(ctx.code).map { Candidate($0) }))
        }
        return actions
    }

    /// Short codes under the selection key each one keeps, plus where the Space
    /// target sits among them (-1 when it is absent). With placeholders on,
    /// every slot is filled so the numbering reads straight down.
    static func shortCodeView(
        entries: [ArrayDictionary.ShortCodeEntry], placeholders: Bool, highlighting target: String?
    ) -> (candidates: [Candidate], indexLabels: String, highlight: Int) {
        let filled = placeholders && !entries.isEmpty
        let values: [String?] = filled
            ? ArrayDictionary.selectionKeys.map { digit in entries.last { $0.label == digit }?.value }
            : entries.map { $0.value }
        return (values.map { $0.map { Candidate($0) } ?? placeholder },
                filled ? ArrayDictionary.selectionKeyLabels : String(entries.map(\.label)),
                target.flatMap { values.firstIndex(of: $0) } ?? -1)
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
        guard !symbols.isEmpty else { return [.beep, .resetContext] }
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
            return [.beep, .resetContext]
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

    /// A selection key from the number row or the keypad, matched by character
    /// the way the host matches index labels, so both read a layout alike.
    private static func isSelectionKey(_ event: KeyEventInput) -> Bool {
        guard event.pureModifiers.isDisjoint(with: [.command, .control, .option]),
              let characters = event.characters, characters.count == 1,
              let char = characters.first else { return false }
        return ArrayDictionary.selectionKeys.contains(char)
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

struct ArrayShortCodePlaceholdersToggle: View {
    @AppStorage private var value: Bool

    init(engine: InputEngine) {
        self._value = AppStorage(
            wrappedValue: ArrayEngine.defaultShowShortCodePlaceholders,
            InputEngine.composedKey(
                engineID: engine.engineID, subKey: ArrayEngine.showShortCodePlaceholdersSubKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Show placeholders for empty short-code slots", isOn: $value)
            Text("Pressing one clears the code you are typing, like any number with no candidate behind it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
