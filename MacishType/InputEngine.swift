import Carbon
import Cocoa
import OSLog

// MARK: - Per-Client State

class InputEngineContext {
    var composingBuffer: [String] = []
    var composingText: String { composingBuffer.joined() }
    var isComposing: Bool { !composingBuffer.isEmpty }

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
        composingBuffer.removeAll()
        stagedText = ""
        isAssociating = false
    }
}

// MARK: - Engine Action

enum EngineAction {
    case insert(String)
    // staged: leading chars confirmed for commit on session end (negative = whole text).
    case updateMarkedText(String, cursor: Int? = nil, emphasis: Range<Int>? = nil, staged: Int = 0)
    case updateCandidates([String], offset: Int = 0, suspendHighlight: Bool = false)
    case commitSelectedCandidate
    case commitCandidateByDigit(Int)
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

    // MARK: Engine Registry

    private static let engines: [String: () -> InputEngine] = [
        "Example": { ExampleEngine.shared },
    ]

    static func engine(for inputModeID: String) -> InputEngine? {
        guard let prefix = Bundle.main.bundleIdentifier else { return nil }
        guard inputModeID.hasPrefix(prefix + ".") else { return nil }
        let suffix = String(inputModeID.dropFirst(prefix.count + 1))
        return engines[suffix]?()
    }

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
                engine.isLoaded = false
            }
        }
    }

    // MARK: Factory

    func createContext() -> InputEngineContext { InputEngineContext() }

    // MARK: Lifecycle

    private(set) var isLoaded = false

    func load() {}
    func unload() {}

    // Override for per-session setup. Loads engine on first call.
    func activate(context: InputEngineContext, clientIdentifier: String?) {
        if !isLoaded {
            #if DEBUG
            Logger.inputEngine.debug("Loading engine: \("\(type(of: self))", privacy: .public)")
            #endif
            load()
            isLoaded = true
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
        candidateWindowVisible: Bool
    ) -> EngineHandleResult {
        let pureModifiers = modifiers.intersection(.deviceIndependentFlagsMask)

        // 1. Command/Control
        if !pureModifiers.intersection([.command, .control]).isEmpty {
            return context.isComposing ? .handled([.noop]) : .notHandled
        }

        // 2. Uppercase letter (skip when Option is held; falls through to fullwidth)
        if !pureModifiers.contains(.option),
           let text = characters, text.count == 1,
           let char = text.first, char.isUppercase, char.isLetter {
            if context.isComposing {
                return .handled([.noop])
            }
            return .handled([.insert(text)])
        }

        // 3. Escape
        if keyCode == 53 {
            guard context.isComposing else { return .notHandled }
            return .handled([.flushStaged()])
        }

        // 4. Navigation (arrow keys, Tab, Home/End, engine-specific extensions)
        if let action = navigationAction(keyCode: keyCode, characters: characters, modifiers: modifiers) {
            guard context.isComposing else { return .notHandled }
            return .handled([action])
        }

        // 5. Enter
        if keyCode == 36 {
            guard context.isComposing else { return .notHandled }
            return .handled([.commitSelectedCandidate])
        }

        // 6. Digit 1-9
        if let text = characters, text.count == 1,
           let char = text.first,
           let digit = char.wholeNumberValue,
           digit >= candidateWindowConfiguration.indexBase,
           digit <= min(9, candidateWindowConfiguration.indexBase + candidateWindowConfiguration.pageSize - 1),
           context.isComposing {
            return .handled([.commitCandidateByDigit(digit)])
        }

        // 7. Option+key -> fullwidth
        if pureModifiers.contains(.option),
           let (base, shifted) = usKeyboardLayout[keyCode] {
            let char = pureModifiers.contains(.shift) ? shifted : base
            if let fullwidth = Self.toFullwidth(char) {
                if context.isComposing {
                    return .handled([.noop])
                }
                return .handled([.insert(String(fullwidth))])
            }
        }

        // 8. Not handled
        return .notHandled
    }

    func candidateConfirmed(
        context: InputEngineContext, _ candidate: String
    ) -> [EngineAction] {
        if context.isAssociating {
            return [.flushStaged(candidate)]
        }
        if candidate.count == 1, let first = candidate.first {
            let related = lookupAssociatedCandidates(for: first)
            if !related.isEmpty {
                return [.enterAssociatedMode(candidate, related)]
            }
        }
        return [.flushStaged(candidate)]
    }

    func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String
    ) -> [EngineAction] {
        []
    }

    // MARK: Subclass Override Points

    var candidateWindowConfiguration: CandidateWindowConfiguration { .init() }

    func lookupCandidates(context: InputEngineContext, _ key: String) -> [String] { [] }
    func isValidCompositionCharacter(_ char: Character) -> Bool { false }
    func transformInput(_ text: String) -> String { text }

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
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> EngineAction? {
        let pureModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if !pureModifiers.intersection([.command, .control]).isEmpty { return nil }

        if let nav = navigationAction(keyCode: keyCode, characters: characters, modifiers: modifiers) {
            return nav
        }
        if keyCode == 36 { return .commitSelectedCandidate }
        if keyCode == 53 { return .flushStaged() }
        if pureModifiers.isDisjoint(with: [.shift, .option]),
           let text = characters, text.count == 1,
           let char = text.first, let digit = char.wholeNumberValue,
           digit >= candidateWindowConfiguration.indexBase,
           digit <= min(9, candidateWindowConfiguration.indexBase + candidateWindowConfiguration.pageSize - 1) {
            return .commitCandidateByDigit(digit)
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
