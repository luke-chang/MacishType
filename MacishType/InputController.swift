import Cocoa
import InputMethodKit

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}

enum InputState {
    case none
    case composing
}

private func toFullwidth(_ char: Character) -> Character? {
    if char == " " { return "\u{3000}" }
    guard let ascii = char.asciiValue, ascii >= 0x21, ascii <= 0x7E else { return nil }
    return Character(UnicodeScalar(UInt32(ascii) + 0xFEE0)!)
}

// US keyboard layout: keyCode → (base, shifted) character
private let usKeyboardLayout: [UInt16: (Character, Character)] = [
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

private let validCompositionCharacters = Set("abcdefghijklmnopqrstuvwxyz")

@objc(InputController)
class InputController: IMKInputController {
    private var composingText: [String] = []
    private var inputState: InputState = .none

    private lazy var inputMethodMenu: NSMenu = {
        let menu = NSMenu()
        let aboutItem = NSMenuItem(
            title: String(localized: "About MacishType"),
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        return menu
    }()

    override func menu() -> NSMenu! { inputMethodMenu }

    @MainActor @objc private func showAboutWindow(_ sender: Any?) {
        WindowManager.shared.openAbout()
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        hideCandidateWindow()
        CandidateWindow.shared.candidateDelegate = self
    }

    override func deactivateServer(_ sender: Any!) {
        resetState()
        if let client = sender as? IMKTextInput {
            refreshMarkedText(client: client)
        }
        // IMKit may call activateServer on a new controller before deactivateServer
        // on the old one. Only hide the candidate window if we still own it.
        if CandidateWindow.shared.candidateDelegate === self {
            hideCandidateWindow()
        }
        super.deactivateServer(sender)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else {
            return false
        }

        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            return inputState != .none
        }

        if let text = event.characters, text.count == 1,
           let char = text.first, char.isUppercase, char.isLetter {
            if inputState == .none {
                client.insertText(text, replacementRange: .notFound)
            }
            return true
        }

        if event.keyCode == 53 { // Escape
            guard inputState != .none else { return false }
            endComposition(client: client)
            return true
        }

        if let (direction, wrapping) = navigationDirection(for: event) {
            guard inputState != .none else { return false }
            CandidateWindow.shared.handleNavigation(direction: direction, wrapping: wrapping)
            return true
        }

        return handleComposingEvent(event, client: client)
    }

    // MARK: - Shared Utilities

    private func resetState() {
        composingText.removeAll()
        inputState = .none
    }

    private func endComposition(_ candidate: String? = nil, client: IMKTextInput) {
        if let candidate {
            client.insertText(candidate, replacementRange: .notFound)
        }
        resetState()
        if candidate == nil {
            refreshMarkedText(client: client)
        }
        updateCandidates(nil, client: client)
    }

    private func navigationDirection(for event: NSEvent!) -> (NavigationDirection, wrapping: Bool)? {
        switch event.keyCode {
        case 48:
            return (event.modifierFlags.contains(.shift) ? .left : .right, wrapping: true)
        case 123: return (.left, wrapping: false)
        case 124: return (.right, wrapping: false)
        case 125, 121: return (.down, wrapping: false)
        case 126, 116: return (.up, wrapping: false)
        case 115: return (.home, wrapping: false)
        case 119: return (.end, wrapping: false)
        default:
            if event.characters == ">" { return (.down, wrapping: false) }
            if event.characters == "<" { return (.up, wrapping: false) }
            return nil
        }
    }

    private func refreshMarkedText(client: IMKTextInput) {
        let text = composingText.joined()
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0
            ]
        )
        client.setMarkedText(
            attributedText,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: .notFound
        )
    }

    // Some apps (e.g. iMessage) return origin (0, 0) for certain character
    // indices. Start from index 0 to anchor the window at the composition
    // start, and try subsequent indices as fallback.
    // Reference: McBopomofo and vChewing use the same retry pattern.
    private func showCandidateWindow(client: IMKTextInput) {
        var lineHeightRect = NSRect.zero
        let markedTextLength = composingText.joined().utf16.count
        var cursor = 0
        while lineHeightRect.origin == .zero && cursor < markedTextLength {
            _ = client.attributes(forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            cursor += 1
        }
        CandidateWindow.shared.showNear(rect: lineHeightRect)
    }

    private func hideCandidateWindow() {
        CandidateWindow.shared.hide()
    }

    private func updateCandidates(_ candidates: [String]?, client: IMKTextInput) {
        guard let candidates, !candidates.isEmpty else {
            hideCandidateWindow()
            return
        }
        CandidateWindow.shared.updateCandidates(candidates)
        showCandidateWindow(client: client)
    }

    // MARK: - Composing Mode

    private func handleComposingEvent(_ event: NSEvent!, client: IMKTextInput) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.option),
           let (base, shifted) = usKeyboardLayout[event.keyCode] {
            let char = modifiers.contains(.shift) ? shifted : base
            if let fullwidth = toFullwidth(char) {
                if inputState == .none {
                    client.insertText(String(fullwidth), replacementRange: .notFound)
                }
                return true
            }
        }

        switch event.keyCode {
        case 36: // Enter
            guard inputState == .composing else { return false }
            CandidateWindow.shared.commitSelectedCandidate()
            return true

        case 49: // Space
            guard inputState == .composing else { return false }
            if CandidateWindow.shared.isVisible {
                CandidateWindow.shared.commitSelectedCandidate()
            } else {
                endComposition(client: client)
            }
            return true

        case 51: // Backspace
            guard inputState == .composing else { return false }
            _ = composingText.popLast()
            refreshMarkedText(client: client)
            if composingText.isEmpty {
                resetState()
            }
            refreshComposingCandidates(client: client)
            return true

        default:
            guard let text = event.characters, text.count == 1,
                  let char = text.first else {
                return inputState != .none
            }

            if let digit = char.wholeNumberValue, digit >= 1, digit <= 9,
               inputState == .composing {
                CandidateWindow.shared.commitCandidateForDigit(digit)
                return true
            }

            if validCompositionCharacters.contains(char) {
                if inputState == .none { inputState = .composing }
                composingText.append(text.uppercased())
                refreshMarkedText(client: client)
                refreshComposingCandidates(client: client)
                return true
            }

            return inputState != .none
        }
    }

    private func refreshComposingCandidates(client: IMKTextInput) {
        let candidates = composingText.isEmpty ? [] : lookupCandidates(composingText.joined())
        updateCandidates(candidates, client: client)
    }

    // Each letter maps to its fullwidth uppercase equivalent.
    // Input "ABC" returns ["Ａ", "Ｂ", "Ｃ"], no deduplication.
    private func lookupCandidates(_ key: String) -> [String] {
        key.compactMap { char in
            toFullwidth(char).map(String.init)
        }
    }
}

// MARK: - CandidateWindowDelegate

extension InputController: CandidateWindowDelegate {
    func candidateSelected(_ candidate: String) {
        guard let client = client() else { return }
        endComposition(candidate, client: client)
    }

    func candidateSelectionChanged(_ candidate: String) {
    }
}
