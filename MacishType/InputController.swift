import Cocoa
import InputMethodKit

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}

enum InputState {
    case none
    case composing
}

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
    }

    override func deactivateServer(_ sender: Any!) {
        resetState()
        if let client = sender as? IMKTextInput {
            refreshMarkedText(client: client)
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

        if event.keyCode == 53 { // Escape
            guard inputState != .none else { return false }
            endComposition(client: client)
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

    // MARK: - Composing Mode

    private func handleComposingEvent(_ event: NSEvent!, client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case 36: // Enter
            guard inputState == .composing else { return false }
            endComposition(composingText.joined(), client: client)
            return true

        case 49: // Space
            guard inputState == .composing else { return false }
            endComposition(composingText.joined(), client: client)
            return true

        case 51: // Backspace
            guard inputState == .composing else { return false }
            _ = composingText.popLast()
            refreshMarkedText(client: client)
            if composingText.isEmpty {
                resetState()
            }
            return true

        default:
            guard let text = event.characters, text.count == 1,
                  let char = text.first else {
                return inputState != .none
            }

            if validCompositionCharacters.contains(char) {
                if inputState == .none { inputState = .composing }
                composingText.append(text)
                refreshMarkedText(client: client)
                return true
            }

            return inputState != .none
        }
    }
}
