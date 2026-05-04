import Cocoa
import SwiftUI

private let validCompositionCharacters = Set("abcdefghijklmnopqrstuvwxyz")

class ExampleEngineContext: InputEngineContext {
    var firstCandidate: String?

    override func reset() {
        super.reset()
        firstCandidate = nil
    }
}

class ExampleEngine: InputEngine {
    static let shared = ExampleEngine()

    override class var engineID: String { "Example" }

    // Default to on so a fresh install shows the associated-phrase demo
    // without requiring the user to open Settings first.
    override class var defaultShowAssociatedWords: Bool { true }

    override var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engineType: Self.self)
                Section("Typing") {
                    InputEngine.ShowAssociatedWordsToggle(engineType: Self.self)
                }
            }
        )
    }

    override func createContext() -> InputEngineContext { ExampleEngineContext() }

    private func lookupCandidates(_ key: String) -> [String] {
        key.compactMap { Self.toFullwidth($0).map(String.init) }
    }

    override func handleKey(
        context: InputEngineContext,
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let base = super.handleKey(
            context: context, keyCode: keyCode, characters: characters,
            modifiers: modifiers, candidateWindow: candidateWindow)
        if case .handled = base { return base }

        if !modifiers.intersection(.deviceIndependentFlagsMask).isEmpty {
            return .notHandled
        }

        guard let text = characters, text.count == 1,
              let char = text.first else {
            return context.isComposing ? .handled([.noop]) : .notHandled
        }

        let ctx = context as! ExampleEngineContext

        switch keyCode {
        case 49: // Space
            guard context.isComposing else { return .notHandled }
            if let first = ctx.firstCandidate {
                return .handled([.commit(first)])
            }
            return .handled([.resetContext])

        case 51: // Backspace
            guard context.isComposing else { return .notHandled }
            _ = context.composingBuffer.popLast()
            if !context.isComposing {
                return .handled([.resetContext])
            }
            let marked = context.composingText
            let candidates = lookupCandidates(marked)
            ctx.firstCandidate = candidates.first
            return .handled([.updateMarkedText(marked), .updateCandidates(candidates)])

        default:
            if validCompositionCharacters.contains(char) {
                context.composingBuffer.append(text.uppercased())
                let marked = context.composingText
                let candidates = lookupCandidates(marked)
                ctx.firstCandidate = candidates.first
                return .handled([.updateMarkedText(marked), .updateCandidates(candidates)])
            }
            return context.isComposing ? .handled([.noop]) : .notHandled
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
