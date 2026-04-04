import Cocoa

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
    case updateMarkedText(String)
    case updateCandidates([String])
    case commitSelectedCandidate
    case commitCandidateByDigit(Int)
    case navigateCandidates(direction: NavigationDirection, wrapping: Bool, moveOnExpand: Bool)
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

    // MARK: Factory

    func createContext() -> InputEngineContext { InputEngineContext() }

    // MARK: Lifecycle

    func activate(context: InputEngineContext, clientIdentifier: String?) -> [EngineAction] {
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
           digit >= indexBase, digit <= min(9, indexBase + pageSize - 1),
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

    var indexBase: Int { 1 }
    var pageSize: Int { 9 }

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
            return .navigateCandidates(direction: dir, wrapping: true, moveOnExpand: true)
        case 123: // Left
            return .navigateCandidates(direction: .left, wrapping: false, moveOnExpand: true)
        case 124: // Right
            return .navigateCandidates(direction: .right, wrapping: false, moveOnExpand: true)
        case 125: // Down
            return .navigateCandidates(direction: .down, wrapping: false, moveOnExpand: false)
        case 126: // Up
            return .navigateCandidates(direction: .up, wrapping: false, moveOnExpand: false)
        case 116: // Page Up
            return .navigateCandidates(direction: .pageUp, wrapping: false, moveOnExpand: false)
        case 121: // Page Down
            return .navigateCandidates(direction: .pageDown, wrapping: false, moveOnExpand: false)
        case 115: // Home
            return .navigateCandidates(direction: .home, wrapping: false, moveOnExpand: false)
        case 119: // End
            return .navigateCandidates(direction: .end, wrapping: false, moveOnExpand: false)
        default:
            return nil
        }
    }
}
