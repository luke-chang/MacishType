import Cocoa

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
    private override init() { super.init() }

    override func createContext() -> InputEngineContext { ExampleEngineContext() }

    override func isValidCompositionCharacter(_ char: Character) -> Bool {
        validCompositionCharacters.contains(char)
    }

    override func transformInput(_ text: String) -> String {
        text.uppercased()
    }

    override func lookupCandidates(context: InputEngineContext, _ key: String) -> [String] {
        key.compactMap { Self.toFullwidth($0).map(String.init) }
    }

    override func handleKey(
        context: InputEngineContext,
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidateWindowVisible: Bool
    ) -> EngineHandleResult {
        let base = super.handleKey(
            context: context, keyCode: keyCode, characters: characters,
            modifiers: modifiers, candidateWindowVisible: candidateWindowVisible)
        if case .handled = base { return base }

        let ctx = context as! ExampleEngineContext

        guard let text = characters, text.count == 1,
              let char = text.first else {
            return context.isComposing ? .handled([.noop]) : .notHandled
        }

        switch keyCode {
        case 49: // Space
            guard context.isComposing else { return .notHandled }
            if let first = ctx.firstCandidate {
                context.reset()
                return .handled([.insert(first), .updateCandidates([])])
            }
            context.reset()
            return .handled([.updateMarkedText(""), .updateCandidates([])])

        case 51: // Backspace
            guard context.isComposing else { return .notHandled }
            _ = context.composingBuffer.popLast()
            if !context.isComposing {
                return .handled([.updateMarkedText(""), .updateCandidates([])])
            }
            let marked = context.composingText
            let candidates = lookupCandidates(context: context, marked)
            ctx.firstCandidate = candidates.first
            return .handled([.updateMarkedText(marked), .updateCandidates(candidates)])

        default:
            if isValidCompositionCharacter(char) {
                context.composingBuffer.append(transformInput(text))
                let marked = context.composingText
                let candidates = lookupCandidates(context: context, marked)
                ctx.firstCandidate = candidates.first
                return .handled([.updateMarkedText(marked), .updateCandidates(candidates)])
            }
            return context.isComposing ? .handled([.noop]) : .notHandled
        }
    }
}
