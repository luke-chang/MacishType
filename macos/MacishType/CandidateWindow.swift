import Cocoa

// MARK: - Shared Types

/// A single candidate displayed in the candidate window. `annotation` is an
/// optional descriptive string shown after the candidate text to disambiguate
/// symbols or abbreviated text.
struct Candidate {
    let text: String
    /// Empty string normalized to nil at init — `nil` and `""` carry the
    /// same "no annotation" semantic; collapsing here keeps render path
    /// and panel-level measurement from drifting on the empty case.
    let annotation: String?
    /// Engine-defined opaque carry-through. Lets engines round-trip identifiers
    /// (absolute index, primary key, etc.) to confirm/select callbacks without
    /// value-lookup ambiguity.
    let payload: Any?

    init(_ text: String, annotation: String? = nil, payload: Any? = nil) {
        self.text = text
        self.annotation = annotation?.isEmpty == true ? nil : annotation
        self.payload = payload
    }
}

enum NavigationDirection: Hashable {
    case up, down, left, right, home, end, pageUp, pageDown
    case itemForward, itemBackward
    case pageForward, pageBackward
}

struct CandidateWindowConfiguration: Equatable {
    // Pure validators — callable from nonisolated contexts (manifest decode,
    // FSEvents callbacks). Without `nonisolated`, Swift 6 infers main-actor
    // isolation from the enclosing module and the static parsers can't use them.
    nonisolated static let validPageSizeRange: ClosedRange<Int> = 1...11

    nonisolated static func isValidIndexLabels(_ s: String) -> Bool {
        s.allSatisfy(\.isValidIndexLabel)
    }

    nonisolated static func isValidPageSize(_ v: Int) -> Bool {
        validPageSizeRange.contains(v)
    }

    /// `""` collapses the index column; `" "` reserves the slot but renders
    /// blank; otherwise labels render as-is. Duplicate chars are allowed —
    /// `candidateIndex(for:)` matches first occurrence (`firstIndex` semantics).
    var indexLabels: String = "1234567890" {
        didSet {
            precondition(
                Self.isValidIndexLabels(indexLabels),
                "indexLabels must be ASCII printable (0x20-0x7E), got: \(indexLabels)"
            )
        }
    }

    var reservesIndexSlot: Bool { !indexLabels.isEmpty }
    var pageSize: Int = 9 {
        didSet {
            precondition(
                Self.isValidPageSize(pageSize),
                "pageSize must be in \(Self.validPageSizeRange), got: \(pageSize)")
        }
    }
    var widerExpandedColumns = true
    var moveOnExpand = false
    var animationDuration: TimeInterval = 0.183
    var horizontalMaxVisibleRows = 5
    var verticalMinVisibleRows: Int? = nil
    var expandable = true
    var layoutDirection: CandidateWindow.LayoutDirection = .horizontal
    var fontSize: CGFloat = 16

    /// Host handles standard nav keys (arrows / Tab / Page / Home / End)
    /// and Enter while the window is visible. Set false to route them to
    /// the engine.
    var handleNavigationKeys: Bool = true
    /// Host handles `indexLabels` keys while the window is visible. Set
    /// false to route them to the engine.
    var handleIndexLabelKeys: Bool = true

    /// When true, digit labels select only with Shift + a physical digit key
    /// (main row or keypad); the key's digit looks itself up in `indexLabels`,
    /// so matching is layout-independent (the digit row is shifted on AZERTY).
    /// Non-digit labels keep plain character matching.
    var indexLabelDigitsRequireShift: Bool = false

    /// Page-relative 0-based index for `char` if it maps to a labelled
    /// position within `pageSize`. Whitespace returns nil — engines
    /// decide what space (and other whitespace) keys do.
    func candidateIndex(for char: Character) -> Int? {
        guard !char.isWhitespace else { return nil }
        for (index, c) in indexLabels.prefix(pageSize).enumerated() where c == char {
            return index
        }
        return nil
    }

    /// Keystroke lookup shared by the controller and the JS bridge.
    /// Option-modified keys never select; an unknown `code` degrades to
    /// character matching.
    func candidateIndex(
        forWebCode code: String, shift: Bool, option: Bool, character: Character?
    ) -> Int? {
        guard !option else { return nil }
        if indexLabelDigitsRequireShift,
           let digit = KeyboardEventMapping.digitCharacter(forWebCode: code) {
            return shift ? candidateIndex(for: digit) : nil
        }
        guard let character else { return nil }
        return candidateIndex(forTypedCharacter: character)
    }

    /// `candidateIndex(for:)` with the Shift-requirement gate: a bare
    /// character carries no keystroke identity, so digit labels never match
    /// through it while `indexLabelDigitsRequireShift` is on.
    func candidateIndex(forTypedCharacter character: Character) -> Int? {
        if indexLabelDigitsRequireShift, character.isDigitIndexLabel { return nil }
        return candidateIndex(for: character)
    }

    /// Standard nav-key lookup: arrows / Tab / Page / Home / End. Returns nil
    /// when `keyCode` isn't a nav key, or when a modifier disqualifies it.
    /// Cmd / Ctrl are filtered upstream so they never reach here.
    ///
    /// Tab is the only nav key that reads a modifier (Shift, to reverse). Holding
    /// Option — or Shift on any other key — means it's no longer a plain
    /// navigation key, so leave it for the engine (e.g. an engine's paging binding).
    func navigationIntent(
        keyCode: UInt16, shift: Bool, option: Bool
    ) -> (direction: NavigationDirection, wrapping: Bool)? {
        guard !option else { return nil }
        if keyCode == KeyCode.tab {
            return (shift ? .itemBackward : .itemForward, true)
        }
        guard !shift else { return nil }
        switch keyCode {
        case KeyCode.leftArrow:  return (.left, false)
        case KeyCode.rightArrow: return (.right, false)
        case KeyCode.downArrow:  return (.down, false)
        case KeyCode.upArrow:    return (.up, false)
        case KeyCode.pageUp:     return (.pageUp, false)
        case KeyCode.pageDown:   return (.pageDown, false)
        case KeyCode.home:       return (.home, false)
        case KeyCode.end:        return (.end, false)
        default:                 return nil
        }
    }
}

extension Character {
    /// Whether this character is a valid `indexLabels` entry: a single
    /// ASCII printable scalar in the range 0x20-0x7E (includes space).
    nonisolated var isValidIndexLabel: Bool {
        guard unicodeScalars.count == 1, let s = unicodeScalars.first else { return false }
        return s.value >= 0x20 && s.value <= 0x7E
    }

    /// ASCII digit — the label class `indexLabelDigitsRequireShift` governs.
    nonisolated var isDigitIndexLabel: Bool {
        ("0"..."9").contains(self)
    }
}

extension Range where Bound == Int {
    /// The absolute candidate index a page-relative label position addresses,
    /// nil when that slot holds no candidate.
    nonisolated func absoluteIndex(forPageIndex index: Int) -> Int? {
        let absolute = lowerBound + index
        return contains(absolute) ? absolute : nil
    }
}

protocol CandidateWindowDelegate: AnyObject {
    /// Called when a candidate is committed. `candidate` is the chosen
    /// string, or `""` when commitSelectedCandidate was invoked on a visible
    /// window with no active selection; `raw` is `nil` and `absoluteIndex` is
    /// `-1` in that case. A hidden window fires nothing at all.
    /// `absoluteIndex` is into the candidates array emitted
    /// by the most recent updateCandidates (distinct from the
    /// page-relative index taken by `commitCandidateAtIndex(_)`).
    func candidateConfirmed(_ candidate: String, absoluteIndex: Int, raw: Candidate?)
    func candidateSelectionChanged(_ candidate: String, absoluteIndex: Int, raw: Candidate)
}

protocol CandidateItemClickable: AnyObject {
    var didDrag: Bool { get }
    func itemClicked(at index: Int, doubleClick: Bool)
}

// MARK: - CandidateWindow (Singleton Router)

class CandidateWindow {

    static let shared = CandidateWindow()

    enum LayoutDirection: String, Decodable {
        case horizontal
        case vertical
    }

    enum Style {
        case sequoia
        case tahoe
    }

    /// Candidate window implementations, named after the manifest
    /// `candidateWindow` section each one reads.
    enum Implementation {
        case macish
    }

    private static var autoResolvedStyle: Style {
        if #available(macOS 26, *) { return .tahoe }
        return .sequoia
    }

    private static var styleOverride: Style?

    private static var resolvedStyle: Style { styleOverride ?? autoResolvedStyle }

    /// Implementation the current style builds, resolved without touching
    /// the singleton — manifest loading must not bring up the panel.
    static var activeImplementation: Implementation {
        switch resolvedStyle {
        case .sequoia, .tahoe: .macish
        }
    }

    // MARK: - Impl Instances

    private var _impl: CandidateWindowImpl?

    private var activeImpl: CandidateWindowImpl {
        if let existing = _impl { return existing }
        let instance: CandidateWindowImpl = switch Self.activeImplementation {
        case .macish: MacishCandidateWindow(style: Self.resolvedStyle)
        }
        instance.owner = self
        _impl = instance
        return instance
    }

    func setStyle(_ override: Style?) {
        guard override != Self.styleOverride else { return }
        Self.styleOverride = override
        guard let old = _impl else { return }
        let wasVisible = old.isVisible
        let savedCandidates = old.candidates
        old.hide()
        _impl = nil
        apply()
        if let message = messageText {
            // A redraw, not a new message: a running `duration` keeps counting.
            renderMessage(message)
        } else if !savedCandidates.isEmpty {
            updateCandidates(savedCandidates, initialHighlight: 0)
        }
        if wasVisible {
            show(near: lastShowNearRect)
        }
        activeImpl.syncTheme()
    }

    // MARK: - Configuration

    private var engineConfiguration = CandidateWindowConfiguration()

    /// Live configuration currently applied. `InputController` reads it
    /// to drive policy-gated key dispatch and to build the
    /// `CandidateWindowState` snapshot passed to engine hooks, so
    /// engines see the effective indexLabels / pageSize (including
    /// per-update overrides).
    var currentConfiguration: CandidateWindowConfiguration { engineConfiguration }

    /// What the panel is currently rendering with: `engineConfiguration`, or
    /// the message's derived form while one is up.
    private var appliedConfiguration = CandidateWindowConfiguration()

    // MARK: - State

    /// Text of the message shown in place of candidates.
    private(set) var messageText: String? {
        didSet {
            if messageText == nil { messageDismissal = nil }
        }
    }
    /// Replacing or clearing it cancels it, which releases it at once: engines
    /// pick the deadline, and it can be days out.
    private var messageDismissal: DispatchSourceTimer? {
        didSet { oldValue?.cancel() }
    }
    /// Bumped by every `hide()`, so a caller can tell whether a synchronous
    /// callback dismissed the window between two of its own steps. A message's
    /// `duration` running out also hides, between events.
    private(set) var hideCount = 0

    private(set) var lastShowNearRect: NSRect = .zero

    // Composition bounds for left/right candidate window positioning
    var compositionStartX: CGFloat = 0
    private var _compositionEndX: CGFloat?
    private var _compositionEndXProvider: (() -> CGFloat)?

    func setCompositionEndXProvider(_ provider: (() -> CGFloat)?) {
        _compositionEndXProvider = provider
        _compositionEndX = nil
    }

    var compositionEndX: CGFloat {
        if let cached = _compositionEndX { return cached }
        let value = _compositionEndXProvider?() ?? compositionStartX
        _compositionEndX = value
        return value
    }

    weak var candidateDelegate: CandidateWindowDelegate?
    var clientWindowLevel: CGWindowLevel = CGWindowLevel(CGWindowLevelForKey(.floatingWindow))

    /// Live Shift state driving the Shift-gated digit labels.
    var shiftHeld = false {
        didSet {
            guard shiftHeld != oldValue else { return }
            _impl?.shiftHeldChanged()
        }
    }

    var bundleIdentifier: String?

    var clientAppearance: NSAppearance?

    func syncTheme() {
        activeImpl.syncTheme()
    }

    // MARK: - Delegated Interface

    /// The panel is on screen, whatever it is showing.
    var isVisible: Bool { activeImpl.isVisible }

    /// A candidate window the engine can act on. A message rides the same
    /// panel but is not one.
    var hasCandidates: Bool { messageText == nil && activeImpl.isVisible }

    /// False under a suspended highlight (`initialHighlight: -1`) until a
    /// navigation reveals one.
    var hasSelection: Bool { activeImpl.hasSelection }

    /// Absolute range of the candidate list the current index labels address,
    /// empty while no candidate window is up. Not always everything on screen:
    /// the horizontal expandable panel labels one row at a time.
    var pageRange: Range<Int> { hasCandidates ? activeImpl.pageRange : 0..<0 }

    /// Standalone path (engine activation, preview app).
    /// Short-circuits when unchanged.
    func configure(_ configuration: CandidateWindowConfiguration) {
        guard engineConfiguration != configuration else { return }
        // A message is drawn with a configuration derived from the old one, so
        // reconfiguring retires it.
        if messageText != nil { hide() }
        engineConfiguration = configuration
        apply()
    }

    private func apply() {
        markApplied(engineConfiguration)
        activeImpl.apply(engineConfiguration)
    }

    /// Combined update — applies `configuration` (when changed) in the
    /// same rebuild as candidates to avoid configure-then-render flicker.
    func updateCandidates(_ candidates: [Candidate], initialHighlight: Int,
                         configuration: CandidateWindowConfiguration? = nil) {
        // A window can open with Shift already down; seed from the hardware
        // state rather than waiting for a flagsChanged transition.
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        messageText = nil
        activeImpl.rowsSelectable = true
        if let configuration { engineConfiguration = configuration }
        // Leaving a message needs a push even when the engine's configuration
        // is unchanged: the message's derived one outlives `messageText`.
        activeImpl.updateCandidates(candidates, initialHighlight: initialHighlight,
                                    configuration: pushable(engineConfiguration))
    }

    /// Shows `text` in place of candidates; empty text dismisses it. A positive
    /// `duration` (milliseconds) dismisses it once it runs out, unless the
    /// message is gone or replaced by then.
    func updateMessage(_ text: String, duration: Int = 0) {
        guard !text.isEmpty else {
            // Nothing to dismiss: leave the candidate window alone.
            if messageText != nil { hide() }
            return
        }
        messageDismissal = nil
        if duration > 0 {
            // It fires outside any IMK callback, so it stays on the panel,
            // never reaching the client or the engine.
            let dismissal = DispatchSource.makeTimerSource(queue: .main)
            dismissal.schedule(deadline: .now() + .milliseconds(duration))
            dismissal.setEventHandler { [weak self] in self?.updateMessage("") }
            dismissal.resume()
            messageDismissal = dismissal
        }
        renderMessage(text)
    }

    /// Horizontal so the row sizes to its text. `engineConfiguration` is left
    /// untouched, so `currentConfiguration` keeps reporting what candidates
    /// would use.
    private func renderMessage(_ text: String) {
        messageText = text
        activeImpl.rowsSelectable = false
        var cfg = engineConfiguration
        cfg.layoutDirection = .horizontal
        cfg.expandable = false
        cfg.indexLabels = ""
        activeImpl.updateCandidates([Candidate(text)], initialHighlight: -1,
                                    configuration: pushable(cfg))
    }

    /// `cfg` when the panel isn't already rendering with it, else nil. Marking
    /// it applied here keeps the index-column slot state in lockstep.
    private func pushable(_ cfg: CandidateWindowConfiguration) -> CandidateWindowConfiguration? {
        guard appliedConfiguration != cfg else { return nil }
        markApplied(cfg)
        return cfg
    }

    /// Single writer for `appliedConfiguration`.
    private func markApplied(_ cfg: CandidateWindowConfiguration) {
        appliedConfiguration = cfg
        MacishCandidateItemView.configureIndexColumn(enabled: cfg.reservesIndexSlot)
    }

    func show(near rect: NSRect) {
        lastShowNearRect = rect
        activeImpl.show(near: rect)
    }

    func hide() {
        hideCount += 1
        compositionStartX = 0
        setCompositionEndXProvider(nil)
        messageText = nil
        activeImpl.hide()
    }

    // Window verbs are silent while hidden: a hidden impl still holds stale
    // candidates, and the contract has engines treat a missing window as
    // nothing to act on. Gating here covers every impl and every window
    // verb; in-panel mouse paths imply a visible panel.

    func handleNavigation(direction: NavigationDirection, wrapping: Bool = false) {
        guard hasCandidates else { return }
        activeImpl.handleNavigation(direction: direction, wrapping: wrapping)
    }

    func commitSelectedCandidate() {
        guard hasCandidates else { return }
        activeImpl.commitSelectedCandidate()
    }

    /// False when the index addresses no candidate, so the caller can leave
    /// the keystroke alone.
    func commitCandidate(at index: Int) -> Bool {
        guard hasCandidates else { return false }
        return activeImpl.commitCandidate(at: index)
    }

    // MARK: - Init

    private init() {
        apply()
    }
}

// MARK: - CandidateWindowImpl (Style Controller Base)

class CandidateWindowImpl {

    weak var owner: CandidateWindow?

    // MARK: - Shared State (from owner)

    var candidateDelegate: CandidateWindowDelegate? { owner?.candidateDelegate }
    var bundleIdentifier: String? { owner?.bundleIdentifier }
    var shiftHeld: Bool { owner?.shiftHeld ?? false }
    var clientWindowLevel: CGWindowLevel { owner?.clientWindowLevel ?? CGWindowLevel(CGWindowLevelForKey(.floatingWindow)) }
    var clientAppearance: NSAppearance? { owner?.clientAppearance }
    var lastShowNearRect: NSRect { owner?.lastShowNearRect ?? .zero }
    var compositionStartX: CGFloat { owner?.compositionStartX ?? 0 }
    var compositionEndX: CGFloat { owner?.compositionEndX ?? compositionStartX }

    // MARK: - Candidate State

    var candidates: [Candidate] = []
    // -1 sentinel = no selection.
    var selectedIndex: Int = -1
    var hasSelection: Bool { selectedIndex >= 0 }
    /// False for a message's row. The keyboard paths are gated by
    /// `CandidateWindow.hasCandidates`; in-panel mouse paths are not.
    var rowsSelectable = true

    func notifySelectionChanged() {
        guard hasSelection, !candidates.isEmpty else { return }
        let selected = candidates[selectedIndex]
        candidateDelegate?.candidateSelectionChanged(
            selected.text, absoluteIndex: selectedIndex, raw: selected)
    }

    // MARK: - Subclass Override Points

    var isVisible: Bool { false }
    /// See `CandidateWindow.pageRange`.
    var pageRange: Range<Int> { 0..<0 }

    func syncTheme() {}

    func shiftHeldChanged() {}

    func apply(_ configuration: CandidateWindowConfiguration) {}
    func updateCandidates(_ candidates: [Candidate], initialHighlight: Int,
                          configuration: CandidateWindowConfiguration?) {}
    func show(near rect: NSRect) {}
    func hide() {}

    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitSelectedCandidate() {}
    func commitCandidate(at index: Int) -> Bool { false }
}
