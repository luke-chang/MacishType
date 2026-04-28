import Cocoa

// MARK: - Shared Types

enum NavigationDirection: Hashable {
    case up, down, left, right, home, end, pageUp, pageDown
    case itemForward, itemBackward
    case pageForward, pageBackward
}

struct CandidateWindowConfiguration: Equatable {
    // Duplicate chars are allowed; the lookup in `candidateIndex(for:)`
    // returns the first occurrence (matches `firstIndex`/`enumerated().first`
    // semantics), so later duplicates are unreachable but not an error.
    var indexLabels: String = "1234567890" {
        didSet {
            precondition(
                indexLabels.allSatisfy(\.isValidIndexLabel),
                "indexLabels must be ASCII printable (0x20-0x7E), got: \(indexLabels)"
            )
        }
    }
    var pageSize: Int = 9 {
        didSet {
            precondition(pageSize >= 1 && pageSize <= 10,
                         "pageSize must be between 1 and 10, got: \(pageSize)")
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
    var isValidIndexLabel: Bool {
        guard unicodeScalars.count == 1, let s = unicodeScalars.first else { return false }
        return s.value >= 0x20 && s.value <= 0x7E
    }
}

protocol CandidateWindowDelegate: AnyObject {
    /// Called when a candidate is committed. `candidate` is the chosen
    /// string, or `""` when the window was in suspendHighlight state and
    /// commitSelectedCandidate was invoked (i.e. no item is actively
    /// selected). Callers decide how to interpret the empty case.
    func candidateConfirmed(_ candidate: String)
    func candidateSelectionChanged(_ candidate: String)
}

protocol CandidateItemClickable: AnyObject {
    var didDrag: Bool { get }
    func itemClicked(at index: Int, doubleClick: Bool)
}

// MARK: - CandidateWindow (Singleton Router)

class CandidateWindow {

    static let shared = CandidateWindow()

    enum LayoutDirection: String {
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

    private var _impl: MacishCandidateWindow?

    private var impl: MacishCandidateWindow {
        if let existing = _impl { return existing }
        let instance = MacishCandidateWindow(style: styleOverride ?? Self.autoResolvedStyle)
        instance.owner = self
        _impl = instance
        return instance
    }

    private var activeImpl: CandidateWindowImpl { impl }

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
            updateCandidates(savedCandidates, suspendHighlight: false)
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

    /// Standalone path (engine activation, preview app). Updates
    /// `fallbackLabels` so empty per-update labels fall back to this
    /// engine's width. Short-circuits when unchanged.
    func configure(_ configuration: CandidateWindowConfiguration) {
        guard engineConfiguration != configuration else { return }
        engineConfiguration = configuration
        MacishCandidateItemView.setFallbackLabels(configuration.indexLabels)
        apply()
    }

    private func apply() {
        activeImpl.apply(engineConfiguration)
    }

    /// Combined update — applies `configuration` (when changed) in the
    /// same rebuild as candidates to avoid configure-then-render flicker.
    /// Does not touch `fallbackLabels`: per-update overrides are temporary.
    func updateCandidates(_ candidates: [String], suspendHighlight: Bool,
                         configuration: CandidateWindowConfiguration? = nil) {
        let cfgToApply: CandidateWindowConfiguration?
        if let cfg = configuration, engineConfiguration != cfg {
            engineConfiguration = cfg
            cfgToApply = cfg
        } else {
            cfgToApply = nil
        }
        activeImpl.updateCandidates(candidates, suspendHighlight: suspendHighlight,
                                    configuration: cfgToApply)
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

    var candidates: [String] = []
    var selectedIndex: Int = 0

    // Visual-only suspension: selectedIndex remains a valid Int but no item is
    // highlighted and selection-change notifications are skipped. Used for
    // associated-phrase candidates, where highlight only appears after the
    // first explicit navigation / click.
    var suspendHighlight: Bool = false

    func notifySelectionChanged() {
        if suspendHighlight { return }
        guard !candidates.isEmpty else { return }
        candidateDelegate?.candidateSelectionChanged(candidates[selectedIndex])
    }

    // MARK: - Subclass Override Points

    var isVisible: Bool { false }

    func syncTheme() {}

    func apply(_ configuration: CandidateWindowConfiguration) {}
    func updateCandidates(_ candidates: [String], suspendHighlight: Bool,
                          configuration: CandidateWindowConfiguration?) {}
    func show(near rect: NSRect) {}
    func hide() {}

    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitSelectedCandidate() {}
    func commitCandidate(at index: Int) {}
}
