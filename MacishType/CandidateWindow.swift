import Cocoa

private extension UserDefaults {
    @objc dynamic var CandidateWindowDirection: String? {
        string(forKey: CandidateWindow.directionKey)
    }
    @objc dynamic var FontSize: Int {
        integer(forKey: CandidateWindow.fontSizeKey)
    }
}

// MARK: - Shared Types

enum NavigationDirection: Hashable {
    case up, down, left, right, home, end, pageUp, pageDown
    case itemForward, itemBackward
    case pageForward, pageBackward
}

struct CandidateWindowConfiguration {
    var indexBase = 1
    var pageSize = 9
    var widerExpandedColumns = true
    var moveOnExpand = false
    var animationDuration: TimeInterval = 0.183
    var horizontalMaxVisibleRows = 5
    var verticalMinVisibleRows: Int? = nil
    var expandable = true
    var layoutDirection: CandidateWindow.LayoutDirection? = nil
    var fontSize: CGFloat? = nil
}

protocol CandidateWindowDelegate: AnyObject {
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

    enum LayoutDirection {
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
            updateCandidates(savedCandidates)
        }
        if wasVisible {
            show(near: lastShowNearRect)
        }
        activeImpl.syncTheme()
    }

    // MARK: - Configuration

    fileprivate static let directionKey = "CandidateWindowDirection"
    fileprivate static let fontSizeKey = "FontSize"

    private var engineConfiguration = CandidateWindowConfiguration()

    private var userDefaultsDirection: LayoutDirection {
        guard let value = UserDefaults.standard.string(forKey: Self.directionKey) else { return .horizontal }
        return switch value {
        case "vertical": .vertical
        default: .horizontal
        }
    }

    private var resolvedDirection: LayoutDirection {
        engineConfiguration.layoutDirection ?? userDefaultsDirection
    }

    private var userDefaultsFontSize: CGFloat {
        let raw = UserDefaults.standard.integer(forKey: Self.fontSizeKey)
        return raw >= 8 ? CGFloat(raw) : 16
    }

    private var resolvedFontSize: CGFloat {
        engineConfiguration.fontSize ?? userDefaultsFontSize
    }

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

    func configure(_ configuration: CandidateWindowConfiguration) {
        engineConfiguration = configuration
        apply()
    }

    private func apply() {
        var resolved = engineConfiguration
        resolved.layoutDirection = resolvedDirection
        resolved.fontSize = resolvedFontSize
        activeImpl.apply(resolved)
    }

    func updateCandidates(_ candidates: [String]) {
        activeImpl.updateCandidates(candidates)
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

    func commitCandidateForDigit(_ digit: Int) {
        activeImpl.commitCandidateForDigit(digit)
    }

    // MARK: - Init

    private var directionObservation: NSKeyValueObservation?
    private var fontSizeObservation: NSKeyValueObservation?

    private init() {
        directionObservation = UserDefaults.standard.observe(
            \.CandidateWindowDirection, options: [.new]
        ) { [weak self] _, _ in
            guard let self, case .none = self.engineConfiguration.layoutDirection else { return }
            self.apply()
        }
        fontSizeObservation = UserDefaults.standard.observe(
            \.FontSize, options: [.new]
        ) { [weak self] _, _ in
            guard let self, self.engineConfiguration.fontSize == nil else { return }
            self.apply()
        }

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

    func notifySelectionChanged() {
        guard !candidates.isEmpty else { return }
        candidateDelegate?.candidateSelectionChanged(candidates[selectedIndex])
    }

    // MARK: - Subclass Override Points

    var isVisible: Bool { false }

    func syncTheme() {}

    func apply(_ configuration: CandidateWindowConfiguration) {}
    func updateCandidates(_ candidates: [String]) {}
    func show(near rect: NSRect) {}
    func hide() {}

    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitSelectedCandidate() {}
    func commitCandidateForDigit(_ digit: Int) {}
}
