import AppKit
import Testing

/// Covers the shared host Option+key full-width policy and its kernel.
/// `EngineAction` isn't `Equatable` (it carries a closure), so results are
/// checked by pattern-matching the case + associated value, not `==`.
@MainActor
struct FullwidthPolicyTests {
    private func makeKey(
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> KeyEventInput {
        KeyEventInput(
            keyCode: 0, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers, isRepeat: false)
    }

    /// The flushed string of a `.handled([.flushStaged(_)])` result, else nil.
    private func flushText(_ result: EngineHandleResult?) -> String? {
        guard case .handled(let actions)? = result,
              case .flushStaged(let text)? = actions.first else { return nil }
        return text
    }

    // MARK: hostOptionFullwidthResult

    @Test func idleOptionMappingKeyCommitsFullwidth() {
        let context = InputEngineContext()
        #expect(flushText(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: [.option]),
            context: context)) == "ａ")
        #expect(flushText(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: " ", modifiers: [.option]),
            context: context)) == "\u{3000}")
        #expect(flushText(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "!", modifiers: [.option]),
            context: context)) == "！")
    }

    @Test func composingOptionMappingKeyIsSwallowed() {
        let context = InputEngineContext()
        context.markedText = "x"
        let result = InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: [.option]),
            context: context)
        guard case .handled(let actions)? = result else {
            Issue.record("expected .handled (swallow) while composing")
            return
        }
        #expect(actions.isEmpty)
    }

    @Test func idleOptionNonMappingKeyDeclines() {
        let context = InputEngineContext()
        // No base char to map (nil), or a non-ASCII base char: both decline.
        for result in [
            InputEngine.hostOptionFullwidthResult(
                for: makeKey(charactersIgnoringModifiers: nil, modifiers: [.option]),
                context: context),
            InputEngine.hostOptionFullwidthResult(
                for: makeKey(charactersIgnoringModifiers: "é", modifiers: [.option]),
                context: context),
        ] {
            guard case .notHandled(let actions)? = result else {
                Issue.record("expected .notHandled for non-mapping Option key")
                return
            }
            #expect(actions.isEmpty)
        }
    }

    @Test func optionWithCommandControlOrNoOptionReturnsNil() {
        let context = InputEngineContext()
        #expect(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: [.option, .command]),
            context: context) == nil)
        #expect(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: [.option, .control]),
            context: context) == nil)
        #expect(InputEngine.hostOptionFullwidthResult(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: []),
            context: context) == nil)
    }

    // MARK: toFullwidth / fullwidthFlushAction kernel

    @Test func toFullwidthMapsAsciiPrintablesAndSpaceOnly() {
        #expect(InputEngine.toFullwidth("a").map(String.init) == "ａ")
        #expect(InputEngine.toFullwidth("A").map(String.init) == "Ａ")
        #expect(InputEngine.toFullwidth("!").map(String.init) == "！")
        #expect(InputEngine.toFullwidth(" ").map(String.init) == "\u{3000}")
        #expect(InputEngine.toFullwidth("é") == nil)       // non-ASCII
        #expect(InputEngine.toFullwidth("\u{7F}") == nil)  // DEL, above printable range
    }

    @Test func fullwidthFlushActionReadsCharactersIgnoringModifiers() {
        guard case .flushStaged(let text)? = InputEngine.fullwidthFlushAction(
            for: makeKey(charactersIgnoringModifiers: "a", modifiers: [.option])) else {
            Issue.record("expected .flushStaged")
            return
        }
        #expect(text == "ａ")
        #expect(InputEngine.fullwidthFlushAction(
            for: makeKey(charactersIgnoringModifiers: nil, modifiers: [.option])) == nil)
        #expect(InputEngine.fullwidthFlushAction(
            for: makeKey(charactersIgnoringModifiers: "é", modifiers: [.option])) == nil)
    }
}
