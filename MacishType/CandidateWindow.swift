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

    // MARK: - Impl Instances

    private lazy var sequoia = SequoiaCandidateWindow()

    private var activeImpl: CandidateWindowImpl { sequoia }

    // MARK: - UserDefaults

    fileprivate static let directionKey = "CandidateWindowDirection"
    fileprivate static let fontSizeKey = "FontSize"

    private var engineLayoutDirection: LayoutDirection?
    private var engineFontSize: CGFloat?

    private var userDefaultsDirection: LayoutDirection {
        guard let value = UserDefaults.standard.string(forKey: Self.directionKey) else { return .horizontal }
        return switch value {
        case "vertical": .vertical
        default: .horizontal
        }
    }

    private var resolvedDirection: LayoutDirection {
        engineLayoutDirection ?? userDefaultsDirection
    }

    private var userDefaultsFontSize: CGFloat {
        let raw = UserDefaults.standard.integer(forKey: Self.fontSizeKey)
        return raw >= 8 ? CGFloat(raw) : 16
    }

    private var resolvedFontSize: CGFloat {
        engineFontSize ?? userDefaultsFontSize
    }

    // MARK: - Authoritative State

    private(set) var lastShowNearRect: NSRect = .zero

    var fontSize: CGFloat = 16 {
        didSet {
            guard fontSize != oldValue else { return }
            activeImpl.fontSizeDidChange()
        }
    }

    var direction: LayoutDirection = .horizontal {
        didSet {
            guard direction != oldValue else { return }
            activeImpl.directionDidChange(from: oldValue)
        }
    }

    weak var candidateDelegate: CandidateWindowDelegate?

    var bundleIdentifier: String? {
        didSet {
            guard bundleIdentifier != oldValue else { return }
            activeImpl.bundleIdentifierDidChange()
        }
    }

    // MARK: - Delegated Interface

    var isVisible: Bool { activeImpl.isVisible }

    func apply(_ configuration: CandidateWindowConfiguration) {
        engineLayoutDirection = configuration.layoutDirection
        engineFontSize = configuration.fontSize
        direction = resolvedDirection
        fontSize = resolvedFontSize
        activeImpl.apply(configuration)
    }

    func updateCandidates(_ candidates: [String]) {
        activeImpl.updateCandidates(candidates)
    }

    func show(near rect: NSRect) {
        lastShowNearRect = rect
        activeImpl.show(near: rect)
    }

    func hide() {
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
        sequoia.owner = self

        // didSet does not fire during init, so trigger manually
        fontSize = userDefaultsFontSize
        activeImpl.fontSizeDidChange()

        directionObservation = UserDefaults.standard.observe(
            \.CandidateWindowDirection, options: [.new]
        ) { [weak self] _, _ in
            guard let self, self.engineLayoutDirection == nil else { return }
            self.direction = self.userDefaultsDirection
        }
        fontSizeObservation = UserDefaults.standard.observe(
            \.FontSize, options: [.new]
        ) { [weak self] _, _ in
            guard let self, self.engineFontSize == nil else { return }
            self.fontSize = self.userDefaultsFontSize
        }
    }
}

// MARK: - CandidateWindowImpl (Style Controller Base)

class CandidateWindowImpl {

    weak var owner: CandidateWindow?

    // MARK: - Shared State (from owner)

    var candidateDelegate: CandidateWindowDelegate? { owner?.candidateDelegate }
    var bundleIdentifier: String? { owner?.bundleIdentifier }
    var direction: CandidateWindow.LayoutDirection { owner?.direction ?? .horizontal }
    var fontSize: CGFloat { owner?.fontSize ?? 16 }
    var lastShowNearRect: NSRect { owner?.lastShowNearRect ?? .zero }

    // MARK: - Candidate State

    var candidates: [String] = []
    var selectedIndex: Int = 0
    var lastAppliedConfiguration = CandidateWindowConfiguration()

    func notifySelectionChanged() {
        guard !candidates.isEmpty else { return }
        candidateDelegate?.candidateSelectionChanged(candidates[selectedIndex])
    }

    // MARK: - Subclass Override Points

    var isVisible: Bool { false }

    func directionDidChange(from oldDirection: CandidateWindow.LayoutDirection) {}
    func fontSizeDidChange() {}
    func bundleIdentifierDidChange() {}

    func apply(_ configuration: CandidateWindowConfiguration) {
        lastAppliedConfiguration = configuration
    }
    func updateCandidates(_ candidates: [String]) {}
    func show(near rect: NSRect) {}
    func hide() {}

    func handleNavigation(direction: NavigationDirection, wrapping: Bool) {}
    func commitSelectedCandidate() {}
    func commitCandidateForDigit(_ digit: Int) {}

    // MARK: - Snapshot / Restore

    struct Snapshot {
        let candidates: [String]
        let selectedIndex: Int
        let configuration: CandidateWindowConfiguration
        let wasVisible: Bool
    }

    func snapshot() -> Snapshot {
        Snapshot(candidates: candidates, selectedIndex: selectedIndex,
                 configuration: lastAppliedConfiguration, wasVisible: isVisible)
    }

    func restore(_ snapshot: Snapshot) {
        apply(snapshot.configuration)
        candidates = snapshot.candidates
        selectedIndex = snapshot.selectedIndex
    }
}
