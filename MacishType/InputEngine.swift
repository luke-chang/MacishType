import Carbon
import Cocoa
import OSLog

// MARK: - Per-Client State

class InputEngineContext {
    var composingBuffer: [String] = []
    var composingText: String { composingBuffer.joined() }
    var isComposing: Bool { !composingBuffer.isEmpty }

    func reset() {
        composingBuffer.removeAll()
    }
}

// MARK: - Engine Action

enum EngineAction {
    case insert(String)
    case updateMarkedText(String, cursor: Int? = nil, emphasis: Range<Int>? = nil)
    case updateCandidates([String], anchor: Int = 0)
    case commitSelectedCandidate
    case commitCandidateByDigit(Int)
    case navigateCandidates(NavigationDirection, wrapping: Bool = false, moveOnExpand: Bool = false)
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

    func activate(context: InputEngineContext, clientIdentifier: String?) -> [EngineAction] {
        if !isLoaded {
            #if DEBUG
            Logger.inputEngine.debug("Loading engine: \("\(type(of: self))", privacy: .public)")
            #endif
            load()
            isLoaded = true
        }
        guard context.isComposing else { return [] }
        let candidates = lookupCandidates(context: context, context.composingText)
        return [.updateMarkedText(context.composingText), .updateCandidates(candidates)]
    }

    func deactivate(context: InputEngineContext, clientIdentifier: String?) -> [EngineAction] {
        guard context.isComposing else { return [] }
        context.reset()
        return [.updateMarkedText(""), .updateCandidates([])]
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
            context.reset()
            return .handled([.updateMarkedText(""), .updateCandidates([])])
        }

        // 4. Navigation (arrow keys, Tab, Home/End)
        if let action = Self.navigationAction(keyCode: keyCode, modifiers: modifiers) {
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
        context.reset()
        return [.insert(candidate), .updateCandidates([])]
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

    // MARK: Utilities

    static func toFullwidth(_ char: Character) -> Character? {
        if char == " " { return "\u{3000}" }
        guard let ascii = char.asciiValue, ascii >= 0x21, ascii <= 0x7E else { return nil }
        return Character(UnicodeScalar(UInt32(ascii) + 0xFEE0)!)
    }

    private static func navigationAction(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> EngineAction? {
        switch keyCode {
        case 48: // Tab
            let dir: NavigationDirection = modifiers.contains(.shift) ? .tabBackward : .tabForward
            return .navigateCandidates(dir, wrapping: true, moveOnExpand: true)
        case 123: // Left
            return .navigateCandidates(.left, moveOnExpand: true)
        case 124: // Right
            return .navigateCandidates(.right, moveOnExpand: true)
        case 125: // Down
            return .navigateCandidates(.down)
        case 126: // Up
            return .navigateCandidates(.up)
        case 116: // Page Up
            return .navigateCandidates(.pageUp)
        case 121: // Page Down
            return .navigateCandidates(.pageDown)
        case 115: // Home
            return .navigateCandidates(.home)
        case 119: // End
            return .navigateCandidates(.end)
        default:
            return nil
        }
    }
}
