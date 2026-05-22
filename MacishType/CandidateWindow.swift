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
}

extension Character {
    /// Whether this character is a valid `indexLabels` entry: a single
    /// ASCII printable scalar in the range 0x20-0x7E (includes space).
    nonisolated var isValidIndexLabel: Bool {
        guard unicodeScalars.count == 1, let s = unicodeScalars.first else { return false }
        return s.value >= 0x20 && s.value <= 0x7E
    }
}

protocol CandidateWindowDelegate: AnyObject {
    /// Called when a candidate is committed. `candidate` is the chosen
    /// string, or `""` when commitSelectedCandidate was invoked with no
    /// active selection; `raw` is `nil` and `absoluteIndex` is `-1` in
    /// that case. `absoluteIndex` is into the candidates array emitted
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

    private static var autoResolvedStyle: Style {
        if #available(macOS 26, *) { return .tahoe }
        return .sequoia
    }

    // MARK: - Impl Instances

    private var styleOverride: Style?

    private var _impl: CandidateWindowImpl?

    private var activeImpl: CandidateWindowImpl {
        if let existing = _impl { return existing }
        let style = styleOverride ?? Self.autoResolvedStyle
        let instance: CandidateWindowImpl = switch style {
        case .sequoia, .tahoe:
            MacishCandidateWindow(style: style)
        }
        instance.owner = self
        _impl = instance
        return instance
    }

    func setStyle(_ override: Style?) {
        guard override != styleOverride else { return }
        styleOverride = override
        guard let old = _impl else { return }
        let wasVisible = old.isVisible
        let savedCandidates = old.candidates
        old.hide()
        _impl = nil
        apply()
        if !savedCandidates.isEmpty {
            updateCandidates(savedCandidates, initialHighlight: 0)
        }
        if wasVisible {
            show(near: lastShowNearRect)
        }
        activeImpl.syncTheme()
    }

    // MARK: - Configuration

    private var engineConfiguration = CandidateWindowConfiguration()

    /// Live configuration currently applied — used by `InputController` to
    /// build `CandidateWindowState` for `handleKey` so engines see the
    /// effective indexLabels / pageSize (including per-update overrides).
    var currentConfiguration: CandidateWindowConfiguration { engineConfiguration }

    // MARK: - State

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

    var bundleIdentifier: String?

    var clientAppearance: NSAppearance?

    func syncTheme() {
        activeImpl.syncTheme()
    }

    // MARK: - Delegated Interface

    var isVisible: Bool { activeImpl.isVisible }

    /// Standalone path (engine activation, preview app).
    /// Short-circuits when unchanged.
    func configure(_ configuration: CandidateWindowConfiguration) {
        guard engineConfiguration != configuration else { return }
        applyEngineConfiguration(configuration)
        apply()
    }

    private func apply() {
        activeImpl.apply(engineConfiguration)
    }

    /// Combined update — applies `configuration` (when changed) in the
    /// same rebuild as candidates to avoid configure-then-render flicker.
    func updateCandidates(_ candidates: [Candidate], initialHighlight: Int,
                         configuration: CandidateWindowConfiguration? = nil) {
        let cfgToApply: CandidateWindowConfiguration?
        if let cfg = configuration, engineConfiguration != cfg {
            applyEngineConfiguration(cfg)
            cfgToApply = cfg
        } else {
            cfgToApply = nil
        }
        activeImpl.updateCandidates(candidates, initialHighlight: initialHighlight,
                                    configuration: cfgToApply)
    }

    /// Single writer for `engineConfiguration` — keeps the index-column
    /// slot state in lockstep with the active configuration.
    private func applyEngineConfiguration(_ cfg: CandidateWindowConfiguration) {
        engineConfiguration = cfg
        MacishCandidateItemView.configureIndexColumn(enabled: cfg.reservesIndexSlot)
    }

    func show(near rect: NSRect) {
        lastShowNearRect = rect
        activeImpl.show(near: rect)
    }

    func hide() {
        compositionStartX = 0
        setCompositionEndXProvider(nil)
        activeImpl.hide()
    }

    func handleNavigation(direction: NavigationDirection, wrapping: Bool = false) {
        activeImpl.handleNavigation(direction: direction, wrapping: wrapping)
    }

    func commitSelectedCandidate() {
        activeImpl.commitSelectedCandidate()
    }

    func commitCandidate(at index: Int) {
        activeImpl.commitCandidate(at: index)
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

    func notifySelectionChanged() {
        guard hasSelection, !candidates.isEmpty else { return }
        let selected = candidates[selectedIndex]
        candidateDelegate?.candidateSelectionChanged(
            selected.text, absoluteIndex: selectedIndex, raw: selected)
    }

    // MARK: - Subclass Override Points

    var isVisible: Bool { false }

    func syncTheme() {}

    func apply(_ configuration: CandidateWindowConfiguration) {}
    func updateCandidates(_ candidates: [Candidate], initialHighlight: Int,
                          configuration: CandidateWindowConfiguration?) {}
    func show(near rect: NSRect) {}
    func hide() {}

    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitSelectedCandidate() {}
    func commitCandidate(at index: Int) {}
}
