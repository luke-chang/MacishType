import Combine
import SwiftUI

@main
enum CandidateWindowPreview {
    static func main() {
        let app = NSApplication.shared
        let delegate = PreviewAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var state: PreviewState!

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        state = PreviewState()

        let hostingView = NSHostingView(rootView: PreviewContentView(state: state))
        let contentSize = hostingView.fittingSize

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CandidateWindow Preview"
        window.level = .floating
        window.contentView = hostingView
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.maxX - contentSize.width - 20
            let y = visibleFrame.maxY - window.frame.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        state.window = window
        state.applyCandidates()

        NSApp.activate(ignoringOtherApps: true)
    }
}

enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system = "Auto"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private class TextViewDelegateProxy: NSObject, NSTextViewDelegate {
    weak var original: (any NSTextViewDelegate)?
    var onUnfocus: (() -> Void)?

    private static let unfocusSelectors: Set<Selector> = [
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.insertNewline(_:)),
    ]

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if Self.unfocusSelectors.contains(selector) {
            onUnfocus?()
            return true
        }
        return original?.textView?(textView, doCommandBy: selector) ?? false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

class PreviewState: ObservableObject, CandidateWindowDelegate {
    let candidateWindow = CandidateWindow.shared
    weak var window: NSWindow? {
        didSet {
            installResignKeyObserver()
            installDidMoveObserver()
            DispatchQueue.main.async { [weak self] in
                self?.installDelegateProxy()
            }
        }
    }

    @Published var candidateText = ""
    @Published var styleOverride: CandidateWindow.Style? = nil
    @Published var slowMotion = false
    @Published var widerColumns = true
    @Published var moveOnExpand = false
    @Published var vertical = false
    @Published var expandable = true
    @Published var fontSize: CGFloat = 16
    @Published var indexLabels: String = "1234567890"
    @Published var pageSize: Int = 9
    @Published var appearanceOverride: AppearanceOverride = .system
    @Published var isEditing = false
    @Published var isEditingIndexLabels = false
    @Published var suspendHighlight = false
    // Set when our own callback flips suspendHighlight back off after the
    // user's first navigation; tells `.onChange` to skip the applyCandidates
    // round-trip so it doesn't clobber the panel's just-moved selection.
    var skipNextSuspendApply = false

    var isEditingAnyText: Bool { isEditing || isEditingIndexLabels }

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignKeyObserver: (any NSObjectProtocol)?
    private var didMoveObserver: (any NSObjectProtocol)?
    private var delegateProxy: TextViewDelegateProxy?
    private var positionStale = false

    init() {
        candidateWindow.candidateDelegate = self
        candidateText = randomCandidates().joined(separator: " ")
        applyConfiguration()
        installKeyMonitor()
        installMouseMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = didMoveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applyStyle() {
        syncPositionIfNeeded()
        candidateWindow.setStyle(styleOverride)
        attachCandidatePanel()
    }

    /// Drives the TextField red-border state and the applyConfiguration
    /// fallback, via the same validator `indexLabels.didSet` enforces.
    var isIndexLabelsValid: Bool {
        CandidateWindowConfiguration.isValidIndexLabels(indexLabels)
    }

    func applyConfiguration() {
        syncPositionIfNeeded()
        var config = CandidateWindowConfiguration()
        config.layoutDirection = vertical ? .vertical : .horizontal
        config.fontSize = fontSize
        // Invalid intermediate input (Chinese chars / duplicates) — apply
        // empty labels so the candidate window stays consistent with the
        // red-bordered TextField rather than crashing the precondition.
        config.indexLabels = isIndexLabelsValid ? indexLabels : ""
        config.pageSize = pageSize
        config.widerExpandedColumns = widerColumns
        config.moveOnExpand = moveOnExpand
        config.expandable = expandable
        if slowMotion { config.animationDuration = 1.0 }
        candidateWindow.configure(config)
        attachCandidatePanel()
    }

    /// Replace non-space whitespace (tabs, newlines, etc.) with spaces.
    /// Returns `true` if the text was modified, meaning `candidateText` will
    /// trigger another `onChange` cycle and the caller can skip further work.
    func normalizeCandidateText() -> Bool {
        let normalized = candidateText.replacing(/\s+/, with: " ")
        guard normalized != candidateText else { return false }
        candidateText = normalized
        return true
    }

    func applyCandidates() {
        // Token format: `text|annotation` (annotation optional). First `|`
        // splits text from annotation; later `|` chars are kept inside
        // annotation. Empty text (leading `|`) skips the token; empty
        // annotation (trailing `|`) treats annotation as nil.
        let candidates: [Candidate] = candidateText
            .split(whereSeparator: \.isWhitespace)
            .compactMap { token in
                let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let text = String(parts[0])
                guard !text.isEmpty else { return nil }
                let annotation = parts.count > 1 ? String(parts[1]) : ""
                return Candidate(text, annotation: annotation.isEmpty ? nil : annotation)
            }
        guard !candidates.isEmpty else {
            candidateWindow.hide()
            return
        }
        candidateWindow.updateCandidates(candidates, initialHighlight: suspendHighlight ? -1 : 0)
        if let window {
            let rect = window.frame
            candidateWindow.show(near: NSRect(x: rect.minX, y: rect.minY - 10, width: 0, height: 20))
        }
        attachCandidatePanel()
    }

    func attachCandidatePanel() {
        guard let window else { return }
        for w in NSApp.windows where w is MacishBasePanel && w.isVisible {
            if !(window.childWindows?.contains(w) ?? false) {
                window.addChildWindow(w, ordered: .above)
            }
        }
    }

    func candidateConfirmed(_ candidate: String, absoluteIndex: Int, raw: Candidate?) {
        if let raw {
            print("Selected: \(candidate) [\(absoluteIndex)] (annotation: \(raw.annotation ?? "nil"))")
        } else {
            print("Selected: <none>")
        }
    }

    func candidateSelectionChanged(_ candidate: String, absoluteIndex: Int, raw: Candidate) {
        print("Changed: \(candidate) [\(absoluteIndex)] (annotation: \(raw.annotation ?? "nil"))")
        // First user nav reveals the highlight; mirror that on the toggle.
        if suspendHighlight {
            skipNextSuspendApply = true
            suspendHighlight = false
        }
    }

    private func focusTextEditor() {
        guard let window = window,
              let textView = window.contentView?.findSubview(ofType: NSTextView.self) else { return }
        window.makeFirstResponder(textView)
        textView.selectAll(nil)
        isEditing = true
    }

    private func installDelegateProxy() {
        guard let textView = window?.contentView?.findSubview(ofType: NSTextView.self) else { return }
        let proxy = TextViewDelegateProxy()
        proxy.original = textView.delegate
        proxy.onUnfocus = { [weak self] in self?.unfocusTextEditor() }
        textView.delegate = proxy
        delegateProxy = proxy
    }

    private func unfocusTextEditor() {
        guard let window,
              let textView = window.firstResponder as? NSTextView else {
            isEditing = false
            return
        }
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        window.makeFirstResponder(nil)
        isEditing = false
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Cmd+L focuses the text editor
            if event.modifierFlags.contains(.command), event.keyCode == 37 {
                self.focusTextEditor()
                return nil
            }

            // Cmd+R randomizes candidates
            if event.modifierFlags.contains(.command), event.keyCode == 15 {
                self.candidateText = randomCandidates().joined(separator: " ")
                return nil
            }

            if self.isEditingAnyText { return event }

            self.syncPositionIfNeeded()

            switch event.keyCode {
            case KeyCode.return, KeyCode.keypadEnter:
                self.candidateWindow.commitSelectedCandidate()
                return nil
            case KeyCode.tab:
                let dir: NavigationDirection = event.modifierFlags.contains(.shift) ? .itemBackward : .itemForward
                self.candidateWindow.handleNavigation(direction: dir, wrapping: true)
                return nil
            case KeyCode.space:
                self.candidateWindow.handleNavigation(direction: .pageForward, wrapping: true); return nil
            case KeyCode.downArrow: self.candidateWindow.handleNavigation(direction: .down); return nil
            case KeyCode.upArrow: self.candidateWindow.handleNavigation(direction: .up); return nil
            case KeyCode.pageUp: self.candidateWindow.handleNavigation(direction: .pageUp); return nil
            case KeyCode.pageDown: self.candidateWindow.handleNavigation(direction: .pageDown); return nil
            case KeyCode.leftArrow: self.candidateWindow.handleNavigation(direction: .left); return nil
            case KeyCode.rightArrow: self.candidateWindow.handleNavigation(direction: .right); return nil
            case KeyCode.home: self.candidateWindow.handleNavigation(direction: .home); return nil
            case KeyCode.end: self.candidateWindow.handleNavigation(direction: .end); return nil
            default:
                if let chars = event.characters {
                    if chars == ">" {
                        self.candidateWindow.handleNavigation(direction: .pageForward); return nil
                    }
                    if chars == "<" {
                        self.candidateWindow.handleNavigation(direction: .pageBackward); return nil
                    }
                }
                return event
            }
        }
    }

    private func syncPositionIfNeeded() {
        guard positionStale, let window, candidateWindow.isVisible else { return }
        positionStale = false
        let rect = window.frame
        candidateWindow.show(near: NSRect(x: rect.minX, y: rect.minY - 10, width: 0, height: 20))
    }

    private func installDidMoveObserver() {
        if let observer = didMoveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.positionStale = true
        }
    }

    private func installResignKeyObserver() {
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.unfocusTextEditor()
        }
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window else { return event }
            let clickedView = window.contentView?.hitTest(event.locationInWindow)
            // Candidate TextEditor: NSTextView with no enclosing NSTextField.
            // TextField field-editor: NSTextView wrapped inside an NSTextField
            // (SwiftUI @FocusState owns its focus).
            let hitCandidateEditor = (clickedView is NSTextView) && (clickedView?.enclosingTextField == nil)
            let hitTextField = (clickedView?.enclosingTextField != nil)

            if hitCandidateEditor {
                DispatchQueue.main.async {
                    self.isEditing = window.firstResponder is NSTextView
                }
            } else if let tv = window.firstResponder as? NSTextView {
                if tv.enclosingTextField == nil {
                    // Candidate editor was focused — unfocus on any non-editor click.
                    self.unfocusTextEditor()
                } else if !hitTextField {
                    // A TextField was focused, click landed outside any
                    // text input — release focus so @FocusState resets.
                    // (TextField → another TextField is left to AppKit.)
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }
}

private extension NSView {
    var enclosingTextField: NSTextField? {
        sequence(first: self, next: \.superview).first(where: { $0 is NSTextField }) as? NSTextField
    }
}

struct PreviewContentView: View {
    @ObservedObject var state: PreviewState
    @FocusState private var indexLabelsFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column: text editor and hints
            VStack(alignment: .leading, spacing: 8) {
                Text("CandidateWindow Preview")
                    .font(.system(size: 16, weight: .bold))

                TextEditor(text: $state.candidateText)
                    .font(.system(size: 14))
                    .frame(maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .background(state.isEditing ? Color(nsColor: .textBackgroundColor) : Color.secondary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(state.isEditing ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.3),
                                    lineWidth: state.isEditing ? 2 : 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isEditing
                         ? "• Press Tab/Enter/Esc to escape"
                         : "• Press ⌘L to edit candidates")
                        .foregroundStyle(state.isEditing ? Color.accentColor : .secondary)
                    Text("• Press ⌘R to randomize candidates")
                        .foregroundStyle(.secondary)
                    Text("• Separate candidates with spaces")
                        .foregroundStyle(.secondary)
                    Text("• Format: text|annotation (annotation optional)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .frame(width: 260)

            Divider()
                .padding(.horizontal, 12)

            // Right column: pickers and toggles
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .centerFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Style:")
                            .gridColumnAlignment(.leading)
                        Picker("", selection: $state.styleOverride) {
                            Text("Auto").tag(CandidateWindow.Style?.none)
                            Text("Sequoia").tag(CandidateWindow.Style?.some(.sequoia))
                            Text("Tahoe").tag(CandidateWindow.Style?.some(.tahoe))
                        }
                        .labelsHidden()
                        .gridColumnAlignment(.leading)
                    }

                    GridRow {
                        Text("Appearance:")
                        Picker("", selection: $state.appearanceOverride) {
                            ForEach(AppearanceOverride.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }

                    GridRow {
                        Text("Font size:")
                        Picker("", selection: $state.fontSize) {
                            ForEach([14, 16, 18, 24, 36], id: \.self) { size in
                                Text("\(size)").tag(CGFloat(size))
                            }
                        }
                        .labelsHidden()
                    }

                    GridRow {
                        Text("Page size:")
                        Picker("", selection: $state.pageSize) {
                            ForEach(1...11, id: \.self) { size in
                                Text("\(size)").tag(size)
                            }
                        }
                        .labelsHidden()
                    }

                    GridRow {
                        Text("Index labels:")
                        TextField("", text: $state.indexLabels)
                            .textFieldStyle(.plain)
                            .focused($indexLabelsFocused)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(state.isIndexLabelsValid
                                          ? Color(nsColor: .textBackgroundColor)
                                          : Color.red.opacity(0.5))
                            )
                            .overlay(
                                // Manual focus ring (`.plain` style drops the
                                // system bezel + ring). Invalid state takes
                                // priority so the red border is visible even
                                // when the field is not focused.
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        !state.isIndexLabelsValid
                                            ? Color.red
                                            : indexLabelsFocused
                                                ? Color.accentColor
                                                : Color(nsColor: .separatorColor),
                                        lineWidth: (!state.isIndexLabelsValid || indexLabelsFocused) ? 2 : 1)
                            )
                            .frame(width: 120)
                            // Mirror focus to state so the keyMonitor knows
                            // to pass keystrokes through (typing edits the
                            // field instead of driving the candidate window).
                            .onChange(of: indexLabelsFocused) {
                                state.isEditingIndexLabels = indexLabelsFocused
                            }
                            // Tab / Enter / Esc escape — same UX as the
                            // candidate text editor.
                            .onKeyPress(.tab) {
                                indexLabelsFocused = false
                                return .handled
                            }
                            .onKeyPress(.escape) {
                                indexLabelsFocused = false
                                return .handled
                            }
                            .onSubmit {
                                indexLabelsFocused = false
                            }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Wider expanded columns", isOn: $state.widerColumns)
                    Toggle("Move on expand", isOn: $state.moveOnExpand)
                    Toggle("Vertical layout", isOn: $state.vertical)
                    Toggle("Expandable", isOn: $state.expandable)
                        .disabled(state.vertical)
                    Divider()
                    Toggle("Slow animations (1s)", isOn: $state.slowMotion)
                    Toggle("Suspend highlight", isOn: $state.suspendHighlight)
                }
                .toggleStyle(.checkbox)
            }
            .frame(width: 240)
        }
        .padding()
        .onChange(of: state.candidateText) {
            guard !state.normalizeCandidateText() else { return }
            state.applyCandidates()
        }
        .onChange(of: state.styleOverride) { state.applyStyle() }
        .onChange(of: state.slowMotion) { state.applyConfiguration() }
        .onChange(of: state.widerColumns) { state.applyConfiguration() }
        .onChange(of: state.moveOnExpand) { state.applyConfiguration() }
        .onChange(of: state.vertical) { state.applyConfiguration() }
        .onChange(of: state.expandable) { state.applyConfiguration() }
        .onChange(of: state.fontSize) { state.applyConfiguration() }
        .onChange(of: state.indexLabels) { state.applyConfiguration() }
        .onChange(of: state.pageSize) { state.applyConfiguration() }
        .onChange(of: state.suspendHighlight) {
            if state.skipNextSuspendApply {
                state.skipNextSuspendApply = false
                return
            }
            state.applyCandidates()
        }
        .onChange(of: state.appearanceOverride) {
            let appearance = state.appearanceOverride.nsAppearance
            state.window?.appearance = appearance
            CandidateWindow.shared.clientAppearance = appearance
            CandidateWindow.shared.syncTheme()
        }
    }
}

#Preview {
    PreviewContentView(state: PreviewState())
}

private extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.findSubview(ofType: type) { return match }
        }
        return nil
    }
}

private let digits: [Character] = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

private func randomCandidates() -> [String] {
    (0..<Int.random(in: 8...20)).map { _ in
        String((0..<Int.random(in: 1...8)).map { _ in digits.randomElement()! })
    }
}
