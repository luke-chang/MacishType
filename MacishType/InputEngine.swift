import Carbon
import Cocoa
import OSLog
import SwiftUI

// MARK: - Per-Client State

class InputEngineContext {
    // Controller mirrors emitted .updateMarkedText into this field, so engines
    // that don't keep their own composing buffer can read marked text here.
    // Engines must mutate this only via the action stream.
    var markedText: String = ""

    var isComposing: Bool { !markedText.isEmpty }

    // Prefix of marked text that the engine has declared as "confirmed, pending
    // commit" via .updateMarkedText(staged:). Flushed on deactivate / .flushStaged.
    var stagedText: String = ""

    // True between paired engine.activate/deactivate hooks (not derivable).
    var isActivated: Bool = false

    // Controller-driven associated-phrase mode. Engines opt-in by emitting
    // .enterAssociatedMode; Controller manages the key flow while this is true.
    // Engines wanting full customization should NOT set this and implement
    // their own state machine.
    var isAssociating: Bool = false

    func reset() {
        markedText = ""
        stagedText = ""
        isAssociating = false
    }
}

// MARK: - Candidate Window State (read-only snapshot)

/// Read-only snapshot passed into `handleKey` so engines decide without
/// mutating the window.
struct CandidateWindowState {
    let isVisible: Bool
    let configuration: CandidateWindowConfiguration
}

// MARK: - Engine Action

enum EngineAction {
    // staged: leading chars confirmed for commit on session end (negative = whole text).
    case updateMarkedText(String, cursor: Int? = nil, emphasis: Range<Int>? = nil, staged: Int = 0)
    // `configure` overrides engine default per-update (associated mode,
    // mode-specific labels, etc.). Nil sticks with engine default.
    case updateCandidates([Candidate], offset: Int = 0, suspendHighlight: Bool = false,
                          configure: ((inout CandidateWindowConfiguration) -> Void)? = nil)
    // Engine-confirmed candidate: routes through engine.candidateConfirmed.
    case commit(Candidate)
    case commitSelectedCandidate
    case commitCandidateAtIndex(Int)
    case navigateCandidates(NavigationDirection, wrapping: Bool = false)
    // Discard-all intent: clear marked text, hide candidate window, reset context.
    case resetContext
    // Keep-confirmed intent: commit stagedText concatenated with the given
    // append string (both may be empty) via a single insertText call, then
    // hide window and reset context.
    case flushStaged(String = "")
    // Enter associated-phrase mode: held char becomes staged marked text,
    // candidates are displayed with offset=1 suspendHighlight=true. Payload
    // carries pre-looked-up candidates so Controller doesn't re-query.
    case enterAssociatedMode(String, [String])
    case noop
}

enum EngineHandleResult {
    case handled([EngineAction])
    case notHandled
}

extension EngineAction {
    /// Convenience for engines that emit candidates as bare strings — wraps
    /// each into `Candidate(_:)` with no annotation. Existing call sites
    /// dispatch here via parameter type inference; sites that want
    /// annotations construct `[Candidate]` directly and hit the case above.
    static func updateCandidates(
        _ texts: [String],
        offset: Int = 0,
        suspendHighlight: Bool = false,
        configure: ((inout CandidateWindowConfiguration) -> Void)? = nil
    ) -> EngineAction {
        .updateCandidates(
            texts.map { Candidate($0) },
            offset: offset,
            suspendHighlight: suspendHighlight,
            configure: configure
        )
    }

    /// Empty candidates payload — controller hides the candidate window
    /// when this is processed. Use when an engine wants to clear pending
    /// candidates while keeping marked text active.
    static let clearCandidates: EngineAction = .updateCandidates([] as [Candidate])

    static func commit(_ text: String) -> EngineAction {
        .commit(Candidate(text))
    }
}

// MARK: - Base Engine

// US keyboard layout: keyCode -> (base, shifted) character
let usKeyboardLayout: [UInt16: (Character, Character)] = [
    0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"),
    4: ("h", "H"), 5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"),
    8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"),
    13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 16: ("y", "Y"),
    17: ("t", "T"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"),
    21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"), 24: ("=", "+"),
    25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"),
    29: ("0", ")"), 30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"),
    33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"), 37: ("l", "L"),
    38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"),
    42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"),
    46: ("m", "M"), 47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
]

class InputEngine {

    // MARK: Engine Registry (static)

    private static let engines: [String: () -> InputEngine] = [
        "Example": { ExampleEngine.shared },
        "JSExternal": { JSExternalEngine.shared },
    ]

    static func engine(for inputModeID: String) -> InputEngine? {
        guard let prefix = Bundle.main.bundleIdentifier,
              inputModeID.hasPrefix(prefix + ".") else { return nil }
        let suffix = String(inputModeID.dropFirst(prefix.count + 1))
        return engines[suffix]?()
    }

    static func engine(forSuffix suffix: String) -> InputEngine? {
        engines[suffix]?()
    }

    /// UserDefaults key: `{engineID}_{subKey}`.
    static func composedKey(engineID: String, subKey: String) -> String {
        "\(engineID)_\(subKey)"
    }

    static let directionSubKey = "candidateWindowDirection"
    static let fontSizeSubKey = "candidateWindowFontSize"
    static let showAssociatedWordsSubKey = "showAssociatedWords"

    /// Subclass override required; `InputEngine` is abstract.
    class var engineID: String { fatalError("Subclasses must override") }

    class var defaultDirection: CandidateWindow.LayoutDirection { .horizontal }
    class var defaultFontSize: Int { 16 }
    class var defaultShowAssociatedWords: Bool { false }

    // MARK: Input Source Monitoring

    private(set) static var enabledEngines: Set<String> = []
    private static var pendingWorkItem: DispatchWorkItem?

    static func observeEnabledEngines() {
        enabledEngines = queryEnabledEngines()
        #if DEBUG
        Logger.inputEngine.debug("Initial enabled engines: \(enabledEngines.sorted(), privacy: .public)")
        #endif

        DistributedNotificationCenter.default().addObserver(
            forName: .init(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            Self.pendingWorkItem?.cancel()
            let item = DispatchWorkItem { Self.updateEnabledEngines() }
            Self.pendingWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    private static func queryEnabledEngines() -> Set<String> {
        let bundleID = Bundle.main.bundleIdentifier!
        let conditions = [
            kTISPropertyBundleID as String: bundleID,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(conditions, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        let ids = sources.compactMap { source in
            TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        }
        let prefix = bundleID + "."
        guard ids.contains(bundleID) else { return [] }
        return Set(ids.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }

    private static func updateEnabledEngines() {
        let newEngines = queryEnabledEngines()
        guard newEngines != enabledEngines else { return }
        let removed = enabledEngines.subtracting(newEngines)
        enabledEngines = newEngines
        #if DEBUG
        Logger.inputEngine.debug("Enabled engines: \(newEngines.sorted(), privacy: .public)")
        #endif
        for key in removed {
            if let engine = engines[key]?(), engine.isLoaded {
                #if DEBUG
                Logger.inputEngine.debug("Unloading engine: \("\(type(of: engine))", privacy: .public)")
                #endif
                engine.unload()
            }
        }
    }

    // MARK: Engine Instance

    // Stored property initializers can't use `Self`, so they reference the
    // base class default. `init()` then calls `reloadConfig()` which picks
    // up `Self.defaultX` overrides and any persisted UserDefaults value.
    var candidateWindowDirection: CandidateWindow.LayoutDirection = InputEngine.defaultDirection
    var candidateWindowFontSize: Int = InputEngine.defaultFontSize
    var showAssociatedWords: Bool = InputEngine.defaultShowAssociatedWords

    init() {
        reloadConfig()
    }

    /// Subclasses override to also reload their own keys; call `super` first.
    func reloadConfig() {
        candidateWindowDirection = defaultsValue(Self.directionSubKey, fallback: Self.defaultDirection)
        candidateWindowFontSize = defaultsValue(Self.fontSizeSubKey, fallback: Self.defaultFontSize)
        showAssociatedWords = defaultsValue(Self.showAssociatedWordsSubKey, fallback: Self.defaultShowAssociatedWords)
    }

    private func defaultsValue<T>(_ subKey: String, fallback: T) -> T {
        let key = Self.composedKey(engineID: Self.engineID, subKey: subKey)
        return (UserDefaults.standard.object(forKey: key) as? T) ?? fallback
    }

    private func defaultsValue<T: RawRepresentable>(_ subKey: String, fallback: T) -> T
        where T.RawValue == String
    {
        let key = Self.composedKey(engineID: Self.engineID, subKey: subKey)
        return UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    // MARK: Factory

    func createContext() -> InputEngineContext { InputEngineContext() }

    // MARK: Lifecycle

    private(set) var isLoaded = false

    /// Subclass setup. Override to perform initialization, then call
    /// `super.load()` to mark the engine loaded. Skipping `super.load()`
    /// (e.g. on failure) keeps `isLoaded == false`, so the next `activate()`
    /// retries.
    func load() { isLoaded = true }

    /// Subclass cleanup. Override to release resources, then call
    /// `super.unload()` to clear `isLoaded`.
    func unload() { isLoaded = false }

    // Override for per-session setup. Loads engine on first call.
    func activate(context: InputEngineContext, clientIdentifier: String?) {
        reloadConfig()
        if !isLoaded {
            #if DEBUG
            Logger.inputEngine.debug("Loading engine: \("\(type(of: self))", privacy: .public)")
            #endif
            load()
        }
    }

    // Override for per-session cleanup (persist learning model, flush caches).
    // Must NOT touch marked text or candidate window — controller handles those.
    func deactivate(context: InputEngineContext, clientIdentifier: String?) {
    }

    // MARK: Event Handling

    func handleKey(
        context: InputEngineContext,
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let pureModifiers = modifiers.intersection(.deviceIndependentFlagsMask)

        // 1. Command/Control
        if !pureModifiers.intersection([.command, .control]).isEmpty {
            return context.isComposing ? .handled([.noop]) : .notHandled
        }

        // 2. Quick-commit by indexLabels — placed before uppercase letter
        //    so letter labels work; option reserved for fullwidth (section 7).
        if context.isComposing,
           !pureModifiers.contains(.option),
           let text = characters, text.count == 1, let char = text.first,
           let index = candidateWindow.configuration.candidateIndex(for: char) {
            return .handled([.commitCandidateAtIndex(index)])
        }

        // 3. Uppercase letter (skip when Option is held; falls through to fullwidth)
        if !pureModifiers.contains(.option),
           let text = characters, text.count == 1,
           let char = text.first, char.isUppercase, char.isLetter {
            if context.isComposing {
                return .handled([.noop])
            }
            return .handled([.flushStaged(text)])
        }

        // 4. Escape
        if keyCode == 53 {
            guard context.isComposing else { return .notHandled }
            return .handled([.flushStaged()])
        }

        // 5. Navigation (arrow keys, Tab, Home/End, engine-specific extensions)
        if let action = navigationAction(keyCode: keyCode, characters: characters, modifiers: modifiers) {
            guard context.isComposing else { return .notHandled }
            return .handled([action])
        }

        // 6. Enter
        if keyCode == 36 {
            guard context.isComposing else { return .notHandled }
            return .handled([.commitSelectedCandidate])
        }

        // 7. Option+key -> fullwidth
        if pureModifiers.contains(.option),
           let (base, shifted) = usKeyboardLayout[keyCode] {
            let char = pureModifiers.contains(.shift) ? shifted : base
            if let fullwidth = Self.toFullwidth(char) {
                if context.isComposing {
                    return .handled([.noop])
                }
                return .handled([.flushStaged(String(fullwidth))])
            }
        }

        // 8. Not handled
        return .notHandled
    }

    func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, raw: Candidate?
    ) -> [EngineAction] {
        if context.isAssociating {
            return [.flushStaged(candidate)]
        }
        if showAssociatedWords,
           candidate.count == 1, let first = candidate.first {
            let related = lookupAssociatedCandidates(for: first)
            if !related.isEmpty {
                return [.enterAssociatedMode(candidate, related)]
            }
        }
        return [.flushStaged(candidate)]
    }

    func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, raw: Candidate
    ) -> [EngineAction] {
        []
    }

    // MARK: Subclass Override Points

    /// Settings UI; subclasses override to add their own sections.
    var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engineType: Self.self)
            }
        )
    }

    var candidateWindowConfiguration: CandidateWindowConfiguration {
        .init(
            layoutDirection: candidateWindowDirection,
            fontSize: CGFloat(candidateWindowFontSize)
        )
    }

    // Associated-phrase lookup. Default returns empty (no associated mode).
    // Engines opt in by overriding with a dictionary query.
    func lookupAssociatedCandidates(for char: Character) -> [String] { [] }

    // Maps a key event to a candidate-window navigation action, or nil if the
    // key isn't a nav key. Default covers standard keyboard nav (Tab, arrows,
    // Page Up/Down, Home, End); subclasses may add engine-specific keys.
    func navigationAction(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> EngineAction? {
        switch keyCode {
        case 48: // Tab
            let dir: NavigationDirection = modifiers.contains(.shift) ? .itemBackward : .itemForward
            return .navigateCandidates(dir, wrapping: true)
        case 123: return .navigateCandidates(.left)
        case 124: return .navigateCandidates(.right)
        case 125: return .navigateCandidates(.down)
        case 126: return .navigateCandidates(.up)
        case 116: return .navigateCandidates(.pageUp)
        case 121: return .navigateCandidates(.pageDown)
        case 115: return .navigateCandidates(.home)
        case 119: return .navigateCandidates(.end)
        default: return nil
        }
    }

    // Composite helper (not for override): maps a key to the action that would
    // apply it to the candidate window. Used by Controller's associated-mode
    // intercept to reuse engine's composing-mode window key semantics.
    // Returns nil when Command/Control are held (system shortcuts must pass).
    final func candidateWindowAction(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
        candidateWindow: CandidateWindowState
    ) -> EngineAction? {
        let pureModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if !pureModifiers.intersection([.command, .control]).isEmpty { return nil }

        if let nav = navigationAction(keyCode: keyCode, characters: characters, modifiers: modifiers) {
            return nav
        }
        if keyCode == 36 { return .commitSelectedCandidate }
        if keyCode == 53 { return .flushStaged() }

        // Live config (not engine default) honors per-update closure
        // overrides — controller intercept in associated mode must use
        // the labels actually displayed.
        if !pureModifiers.contains(.option),
           let text = characters, text.count == 1, let char = text.first,
           let index = candidateWindow.configuration.candidateIndex(for: char) {
            return .commitCandidateAtIndex(index)
        }
        return nil
    }

    // MARK: Utilities

    static func toFullwidth(_ char: Character) -> Character? {
        if char == " " { return "\u{3000}" }
        guard let ascii = char.asciiValue, ascii >= 0x21, ascii <= 0x7E else { return nil }
        return Character(UnicodeScalar(UInt32(ascii) + 0xFEE0)!)
    }

}

// MARK: - SwiftUI Settings Helpers

extension InputEngine {
    /// Wraps content in the project's standard settings Form chrome:
    /// `.formStyle(.grouped)` + `.padding(.top, -20)` to cancel the 20pt
    /// top padding baked into grouped Form (see memory:
    /// swiftui-form-grouped-top-padding).
    static func settingsForm<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .padding(.top, -20)
    }

    /// Engines pass `engineType: Self.self` so the `@AppStorage` fallback
    /// dispatches through `defaultDirection` / `defaultFontSize` overrides,
    /// staying in lockstep with `reloadConfig`.
    struct CandidateWindowSection: View {
        let title: LocalizedStringKey
        let includeDirection: Bool
        let includeFontSize: Bool

        @AppStorage private var direction: CandidateWindow.LayoutDirection
        @AppStorage private var fontSize: Int

        init(
            engineType: InputEngine.Type,
            title: LocalizedStringKey = "Candidate window",
            includeDirection: Bool = true,
            includeFontSize: Bool = true
        ) {
            self.title = title
            self.includeDirection = includeDirection
            self.includeFontSize = includeFontSize
            self._direction = AppStorage(
                wrappedValue: engineType.defaultDirection,
                InputEngine.composedKey(engineID: engineType.engineID, subKey: InputEngine.directionSubKey))
            self._fontSize = AppStorage(
                wrappedValue: engineType.defaultFontSize,
                InputEngine.composedKey(engineID: engineType.engineID, subKey: InputEngine.fontSizeSubKey))
        }

        var body: some View {
            Section(title) {
                if includeDirection {
                    Picker("Orientation:", selection: $direction) {
                        Text("Horizontal").tag(CandidateWindow.LayoutDirection.horizontal)
                        Text("Vertical").tag(CandidateWindow.LayoutDirection.vertical)
                    }
                }
                if includeFontSize {
                    Picker("Font size:", selection: $fontSize) {
                        ForEach([14, 16, 18, 24, 36], id: \.self) {
                            Text(verbatim: "\($0)").tag($0)
                        }
                    }
                }
            }
        }
    }

    /// Toggle for the associated-phrase mode opt-in. Engines opting in to the
    /// feature include this in their `settingsView`.
    struct ShowAssociatedWordsToggle: View {
        @AppStorage private var value: Bool

        init(engineType: InputEngine.Type) {
            self._value = AppStorage(
                wrappedValue: engineType.defaultShowAssociatedWords,
                InputEngine.composedKey(engineID: engineType.engineID, subKey: InputEngine.showAssociatedWordsSubKey))
        }

        var body: some View {
            Toggle("Show predictive completions", isOn: $value)
        }
    }
}
