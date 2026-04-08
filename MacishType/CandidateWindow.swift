import Cocoa

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
    var layoutDirection: CandidateWindow.LayoutDirection = .horizontal
}

protocol CandidateWindowDelegate: AnyObject {
    func candidateSelected(_ candidate: String)
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

    // MARK: - Authoritative State

    private(set) var lastShowNearRect: NSRect = .zero

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

    private init() {
        sequoia.owner = self
    }
}

// MARK: - CandidateWindowImpl (Style Controller Base)

class CandidateWindowImpl {

    weak var owner: CandidateWindow?

    // Read shared state from owner
    var candidateDelegate: CandidateWindowDelegate? { owner?.candidateDelegate }
    var bundleIdentifier: String? { owner?.bundleIdentifier }
    var direction: CandidateWindow.LayoutDirection { owner?.direction ?? .horizontal }
    var lastShowNearRect: NSRect { owner?.lastShowNearRect ?? .zero }

    // MARK: - Subclass Override Points

    func directionDidChange(from oldDirection: CandidateWindow.LayoutDirection) {}
    func bundleIdentifierDidChange() {}
    var isVisible: Bool { false }
    func apply(_ configuration: CandidateWindowConfiguration) {}
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
        Snapshot(candidates: [], selectedIndex: 0, configuration: .init(), wasVisible: false)
    }

    func restore(_ snapshot: Snapshot) {}
}
