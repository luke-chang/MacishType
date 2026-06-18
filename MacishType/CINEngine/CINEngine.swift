import Cocoa
import SwiftUI

/// Per-session state. `code` is the normalized composing buffer; `selecting`
/// marks the candidate-selection phase used by the (two-phase) normal mode.
/// `committedByEndKey` records whether selecting was reached via an endkey
/// (which appended itself to `code`) rather than Space, so backspace can drop
/// the trailing endkey only in the former case.
final class CINEngineContext: InputEngineContext {
    var code = ""
    var selecting = false
    var committedByEndKey = false

    override func reset() {
        super.reset()
        code = ""
        selecting = false
        committedByEndKey = false
    }
}

/// Generic CIN table-based input method. Abstract base: subclasses provide
/// `engineID` and `cinTableURL` (bundled file, or a user-picked file via
/// `CINExternalEngine`).
///
/// Two interaction models, chosen per table by `CINTable.isPreviewable`:
/// - **Preview** (live candidates): used when no candidate-bearing code can be
///   extended by a selkey, so a selkey press while candidates show is
///   unambiguously a selection (handled by the host).
/// - **Normal** (two-phase compose → convert → select): used otherwise.
///   Candidates appear only after Space / an endkey.
class CINEngine: InputEngine {
    static let previewCandidatesSubKey = "previewCandidates"

    var cinTableURL: URL? { nil }
    private(set) var table: CINTable?

    private var previewCandidates = true

    private var characterSetScope = InputEngine.defaultCharacterSetScope

    /// Lazily computed from the table + current coverage; nil = not yet computed
    /// or invalidated by a table / coverage change.
    private var cachedAvailability: InputEngine.ScopeAvailability?

    /// Effective mode: a table that can't be safely previewed is always
    /// normal, ignoring the setting.
    var isEffectivePreview: Bool { (table?.isPreviewable ?? false) && previewCandidates }

    /// Which scope options this table meaningfully offers (for the settings
    /// picker). Computed on first read, then cached. Overridable so a bundled
    /// engine can hardcode it without parsing the table.
    var scopeAvailability: InputEngine.ScopeAvailability {
        if let cachedAvailability { return cachedAvailability }
        let computed = computeAvailability()
        cachedAvailability = computed
        return computed
    }

    func invalidateScopeAvailability() {
        cachedAvailability = nil
    }

    private func computeAvailability() -> InputEngine.ScopeAvailability {
        guard let table else { return .standardOnly }
        var hasSupplementary = false
        var hasUndisplayable = false
        table.enumerateCandidates { _, values in
            guard !(hasSupplementary && hasUndisplayable) else { return }
            for value in values {
                switch FontCoverage.shared.classify(value) {
                case .supplementary: hasSupplementary = true
                case .none: hasUndisplayable = true
                case .basic: break
                }
            }
        }
        return InputEngine.ScopeAvailability(displayable: hasSupplementary, full: hasUndisplayable)
    }

    // MARK: - Lifecycle

    override func createContext() -> InputEngineContext { CINEngineContext() }

    override func reloadConfig() {
        super.reloadConfig()
        previewCandidates = defaultsValue(Self.previewCandidatesSubKey, fallback: true)
        characterSetScope = defaultsValue(Self.characterSetScopeSubKey, fallback: Self.defaultCharacterSetScope)
    }

    override func load() {
        loadTableIfNeeded()
        super.load()
    }

    override func unload() {
        replaceTable(nil)
        super.unload()
    }

    /// Parses the table if not already loaded. Subclasses that need a
    /// security scope (external) hold it around the call.
    func loadTableIfNeeded() {
        guard table == nil, let url = cinTableURL else { return }
        replaceTable(CINTable(contentsOf: url))
    }

    /// The single point through which `table` changes (load, unload, or
    /// external hot-reload). Subclasses override to react — e.g. publishing
    /// the loaded table's name — and must call `super`.
    func replaceTable(_ newTable: CINTable?) {
        table = newTable
        invalidateScopeAvailability()
    }

    /// Parse the table for settings display when inactive, so the preview
    /// toggle's visibility is accurate. External overrides to hold scope.
    func refreshTableForSettings() {
        loadTableIfNeeded()
    }

    // MARK: - Candidate window

    override var candidateWindowConfiguration: CandidateWindowConfiguration {
        var configuration = super.candidateWindowConfiguration
        configuration.expandable = false
        if let table {
            configuration.indexLabels = table.indexLabels
            configuration.pageSize = table.pageSize
        }
        return configuration
    }

    // MARK: - Key handling

    override func handleKey(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        guard let table else { return .notHandled() }
        let ctx = context as! CINEngineContext

        if ctx.code.isEmpty {
            return handleIdle(ctx, keyEvent, table)
        }
        if isEffectivePreview {
            return handlePreview(ctx, keyEvent, candidateWindow, table)
        }
        return ctx.selecting
            ? handleNormalSelecting(ctx, keyEvent, candidateWindow, table)
            : handleNormalComposing(ctx, keyEvent, candidateWindow, table)
    }

    /// Normal selecting-phase: a non-selkey input key commits the staged
    /// highlight, then the host re-dispatches it to start a fresh code.
    override func shouldFlushStagedBeforeHandling(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> Bool {
        guard !isEffectivePreview, let table else { return false }
        let ctx = context as! CINEngineContext
        guard ctx.selecting, let char = inputChar(keyEvent) else { return false }
        // selkeys are committed by the host (handleIndexLabelKeys); only real
        // input keys (those that can begin a code) force a commit-and-restart.
        if candidateWindow.configuration.candidateIndex(for: char) != nil { return false }
        return table.isCodeKey(char)
    }

    override func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate?,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        // Clear staged so the host commits exactly this candidate, keeping
        // marked text non-empty (empty tears down the session → baseline
        // drift if associated mode follows).
        let prefix: [EngineAction] = context.isAssociating ? [] : [.updateMarkedText(candidate, staged: 0)]
        return prefix + super.candidateConfirmed(
            context: context, candidate, absoluteIndex: absoluteIndex, raw: raw,
            candidateWindow: candidateWindow)
    }

    override func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        guard !isEffectivePreview else { return [] }
        let ctx = context as! CINEngineContext
        return ctx.selecting ? [.updateMarkedText(candidate, staged: -1)] : []
    }

    // MARK: - Idle

    private func handleIdle(
        _ ctx: CINEngineContext, _ event: KeyEventInput, _ table: CINTable
    ) -> EngineHandleResult {
        let mods = event.pureModifiers
        if mods.contains(.option), mods.intersection([.command, .control]).isEmpty,
           let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let char = chars.first, let fullwidth = Self.toFullwidth(char) {
            return .handled([.flushStaged(String(fullwidth))])
        }
        guard let char = inputChar(event) else { return .notHandled() }
        guard table.isCodeKey(char) else { return .notHandled() }
        ctx.code = table.normalize(String(char))
        return isEffectivePreview
            ? .handled(renderPreview(ctx, table))
            : .handled(renderComposing(ctx, table))
    }

    // MARK: - Preview mode

    private func handlePreview(
        _ ctx: CINEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ table: CINTable
    ) -> EngineHandleResult {
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                ctx.code = String(ctx.code.dropLast())
                return ctx.code.isEmpty ? .handled([.resetContext]) : .handled(renderPreview(ctx, table))
            case KeyCode.space, KeyCode.return:
                // When candidates show, commit the highlight; otherwise discard.
                // (Return-with-candidates is taken by the host before reaching here.)
                return window.isVisible ? .handled([.commitSelectedCandidate]) : .handled([.resetContext])
            default:
                break
            }
        }
        guard let char = inputChar(event) else { return .handled() }
        let normalized = table.normalize(String(char))
        if ctx.code.count < table.maxCodeLength, table.isCodeKey(char) {
            ctx.code += normalized
            // An endkey acts like pressing Space: commit the top candidate.
            if table.isEndKey(char) {
                let candidates = candidates(for: ctx.code)
                if let first = candidates.first {
                    return .handled([.commit(Candidate(first))])
                }
            }
            return .handled(renderPreview(ctx, table))
        }
        // Can't extend: a selkey while candidates show is handled by the host
        // (the table is previewable, so it can't be an extension); else ignore.
        return .handled([])
    }

    private func renderPreview(_ ctx: CINEngineContext, _ table: CINTable) -> [EngineAction] {
        let candidates = candidates(for: ctx.code)
        return [
            .updateMarkedText(table.rootDisplay(ctx.code)),
            .updateCandidates(candidates.map { Candidate($0) },
                              initialHighlight: candidates.isEmpty ? -1 : 0),
        ]
    }

    // MARK: - Normal mode

    private func handleNormalComposing(
        _ ctx: CINEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ table: CINTable
    ) -> EngineHandleResult {
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                ctx.code = String(ctx.code.dropLast())
                return ctx.code.isEmpty ? .handled([.resetContext]) : .handled(renderComposing(ctx, table))
            case KeyCode.space:
                return .handled(convert(ctx, table))
            default:
                break
            }
        }
        guard let char = inputChar(event) else { return .handled() }
        let normalized = table.normalize(String(char))
        if ctx.code.count < table.maxCodeLength, table.isCodeKey(char) {
            ctx.code += normalized
            // endkey = append then convert (cin.txt: "as if Space were pressed").
            return table.isEndKey(char)
                ? .handled(convert(ctx, table, byEndKey: true))
                : .handled(renderComposing(ctx, table))
        }
        return .handled([])
    }

    private func handleNormalSelecting(
        _ ctx: CINEngineContext, _ event: KeyEventInput,
        _ window: CandidateWindowState, _ table: CINTable
    ) -> EngineHandleResult {
        if event.isBareKey {
            switch event.keyCode {
            case KeyCode.escape:
                return .handled([.resetContext])
            case KeyCode.backspace:
                // Return to composing. An endkey appended itself to `code`, so
                // drop it; Space did not, so keep the full code intact.
                ctx.selecting = false
                if ctx.committedByEndKey {
                    ctx.code = String(ctx.code.dropLast())
                }
                ctx.committedByEndKey = false
                return ctx.code.isEmpty ? .handled([.resetContext]) : .handled(renderComposing(ctx, table))
            case KeyCode.space:
                // Single page → commit the highlight; multiple pages → page.
                let candidates = candidates(for: ctx.code)
                return candidates.count <= window.configuration.pageSize
                    ? .handled([.commitSelectedCandidate])
                    : .handled([.navigateCandidates(.pageForward, wrapping: true)])
            default:
                break
            }
        }
        // selkeys: host. Input keys: shouldFlushStagedBeforeHandling. Rest: swallow.
        return .handled([])
    }

    /// Composing-phase render: reading only, no candidate window. Clearing
    /// candidates also dismisses a lingering "no match" hint.
    private func renderComposing(_ ctx: CINEngineContext, _ table: CINTable) -> [EngineAction] {
        [.updateMarkedText(table.rootDisplay(ctx.code)), .clearCandidates]
    }

    /// Resolve the current code: commit when unique, show candidates when
    /// many, or display a non-interactive "no match" hint when none.
    /// `byEndKey` is true when an endkey (appended to `code`) triggered this,
    /// false for Space; it lets the selecting phase undo the endkey on backspace.
    private func convert(
        _ ctx: CINEngineContext, _ table: CINTable, byEndKey: Bool = false
    ) -> [EngineAction] {
        let candidates = candidates(for: ctx.code)
        if candidates.isEmpty {
            ctx.selecting = false
            return [
                .updateMarkedText(table.rootDisplay(ctx.code)),
                .updateCandidates([Candidate(Self.noMatchHint)], initialHighlight: -1) { configuration in
                    configuration.indexLabels = ""
                    configuration.handleNavigationKeys = false
                    configuration.handleIndexLabelKeys = false
                },
            ]
        }
        if candidates.count == 1 {
            return [.commit(Candidate(candidates[0]))]
        }
        ctx.selecting = true
        ctx.committedByEndKey = byEndKey
        return [
            .updateMarkedText(candidates[0], staged: -1),
            .updateCandidates(candidates.map { Candidate($0) }, initialHighlight: 0),
        ]
    }

    private static var noMatchHint: String { String(localized: "No match") }

    // MARK: - Helpers

    /// The character a keystroke produces (layout- and Shift-aware), or nil if
    /// a meaning-changing modifier (Cmd/Ctrl/Option) is held or it isn't a
    /// single character. Used for code keys; Space/Return/etc. are matched by
    /// keyCode before this.
    private func inputChar(_ event: KeyEventInput) -> Character? {
        guard event.pureModifiers.intersection([.command, .control, .option]).isEmpty,
              let chars = event.characters, chars.count == 1 else { return nil }
        return chars.first
    }

    /// Candidates for `code` under the active character-set scope (filtered at
    /// lookup; `.full` keeps everything and skips classification).
    private func candidates(for code: String) -> [String] {
        let all = table?.lookup(code) ?? []
        guard characterSetScope != .full else { return all }
        return all.filter { characterSetScope.accepts(FontCoverage.shared.classify($0)) }
    }

    // MARK: - Settings

    override var settingsView: AnyView {
        let availability = scopeAvailability
        return AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engine: self)
                Section("Typing") {
                    InputEngine.EnableAssociatedModeToggle(engine: self)
                    if table?.isPreviewable == true {
                        CINPreviewCandidatesToggle(engine: self)
                    }
                    if availability.showsPicker {
                        InputEngine.CharacterSetScopePicker(engine: self, availability: availability)
                    }
                }
            }
        )
    }
}

/// Toggle for live candidate preview, shown only for previewable tables.
struct CINPreviewCandidatesToggle: View {
    @AppStorage private var value: Bool

    init(engine: InputEngine) {
        self._value = AppStorage(
            wrappedValue: true,
            InputEngine.composedKey(engineID: engine.engineID, subKey: CINEngine.previewCandidatesSubKey))
    }

    var body: some View {
        Toggle("Preview candidates while typing", isOn: $value)
    }
}
