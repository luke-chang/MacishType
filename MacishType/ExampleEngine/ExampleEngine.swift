import Cocoa
import SwiftUI

private let validCompositionCharacters = Set("abcdefghijklmnopqrstuvwxyz")

class ExampleEngine: InputEngine {
    static let shared = ExampleEngine()

    override var engineID: String { "Example" }

    // Default to on so demo users see the associated mode feature
    // immediately after enabling Example, without having to open Settings.
    override class var defaultEnableAssociatedMode: Bool { true }

    // A-Z → common zh-Hant characters, for demoing the AssociatedDictionary flow.
    private static let keyMap: [Character: Character] = [
        "A": "的", "B": "是", "C": "一", "D": "不", "E": "有",
        "F": "在", "G": "我", "H": "人", "I": "這", "J": "了",
        "K": "個", "L": "以", "M": "會", "N": "大", "O": "為",
        "P": "來", "Q": "要", "R": "中", "S": "國", "T": "他",
        "U": "到", "V": "就", "W": "們", "X": "上", "Y": "可",
        "Z": "也",
    ]

    private var associatedDictionaryHandle: AssociatedDictionary.Handle?

    override var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engine: self)
                Section("Typing") {
                    InputEngine.EnableAssociatedModeToggle(engine: self)
                }
            }
        )
    }

    override func load() {
        super.load()
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
    }

    override func activate(context: InputEngineContext, clientIdentifier: String?) {
        super.activate(context: context, clientIdentifier: clientIdentifier)
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
    }

    override func unload() {
        associatedDictionaryHandle = nil
        super.unload()
    }

    private func lookupCandidates(_ key: String) -> [String] {
        key.compactMap { Self.keyMap[$0].map(String.init) }
    }

    override func handleKey(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let base = super.handleKey(
            context: context, keyEvent: keyEvent,
            candidateWindow: candidateWindow)
        if case .handled = base { return base }

        if !keyEvent.modifiers.intersection(.deviceIndependentFlagsMask).isEmpty {
            return .notHandled()
        }

        guard let text = keyEvent.characters, text.count == 1,
              let char = text.first else {
            return context.isComposing ? .handled() : .notHandled()
        }

        switch keyEvent.keyCode {
        case 49: // Space
            guard context.isComposing else { return .notHandled() }
            if let first = lookupCandidates(context.markedText).first {
                return .handled([.commit(first)])
            }
            return .handled([.resetContext])

        case 51: // Backspace
            guard context.isComposing else { return .notHandled() }
            let newMarked = String(context.markedText.dropLast())
            if newMarked.isEmpty {
                return .handled([.resetContext])
            }
            return .handled([
                .updateMarkedText(newMarked),
                .updateCandidates(lookupCandidates(newMarked)),
            ])

        default:
            if validCompositionCharacters.contains(char) {
                let newMarked = context.markedText + text.uppercased()
                return .handled([
                    .updateMarkedText(newMarked),
                    .updateCandidates(lookupCandidates(newMarked)),
                ])
            }
            return context.isComposing ? .handled() : .notHandled()
        }
    }

    override func lookupAssociatedCandidates(for char: Character) -> [String] {
        associatedDictionaryHandle?.lookup(char) ?? []
    }
}
