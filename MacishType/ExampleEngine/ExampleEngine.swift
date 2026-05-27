import Cocoa
import SwiftUI

private let validCompositionCharacters = Set("abcdefghijklmnopqrstuvwxyz")

class ExampleEngine: InputEngine {
    static let shared = ExampleEngine()

    override var engineID: String { "Example" }

    // Default to on so demo users see the associated-phrase feature
    // immediately after enabling Example, without having to open Settings.
    override class var defaultShowAssociatedWords: Bool { true }

    override var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engine: self)
                Section("Typing") {
                    InputEngine.ShowAssociatedWordsToggle(engine: self)
                }
            }
        )
    }

    private func lookupCandidates(_ key: String) -> [String] {
        key.compactMap { Self.toFullwidth($0).map(String.init) }
    }

    override func handleKey(
        context: InputEngineContext,
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let base = super.handleKey(
            context: context, keyCode: keyCode, characters: characters,
            modifiers: modifiers, isRepeat: isRepeat,
            candidateWindow: candidateWindow)
        if case .handled = base { return base }

        if !modifiers.intersection(.deviceIndependentFlagsMask).isEmpty {
            return .notHandled
        }

        guard let text = characters, text.count == 1,
              let char = text.first else {
            return context.isComposing ? .handled() : .notHandled
        }

        switch keyCode {
        case 49: // Space
            guard context.isComposing else { return .notHandled }
            if let first = lookupCandidates(context.markedText).first {
                return .handled([.commit(first)])
            }
            return .handled([.resetContext])

        case 51: // Backspace
            guard context.isComposing else { return .notHandled }
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
            return context.isComposing ? .handled() : .notHandled
        }
    }

    override func lookupAssociatedCandidates(for char: Character) -> [String] {
        let s = String(char)
        return [
            String(repeating: s, count: 4),
            String(repeating: s, count: 3),
            String(repeating: s, count: 2),
        ] + Array(repeating: s, count: 20)
    }
}
