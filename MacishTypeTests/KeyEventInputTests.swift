import AppKit
import Carbon.HIToolbox
import Testing

@MainActor
struct KeyEventInputTests {
    private func makeKey(
        _ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> KeyEventInput {
        KeyEventInput(
            keyCode: keyCode, characters: nil, charactersIgnoringModifiers: nil,
            modifiers: modifiers, isRepeat: false)
    }

    @Test func returnAndKeypadEnterAreReturnKeys() {
        #expect(makeKey(KeyCode.return).isReturnKey)
        #expect(makeKey(KeyCode.keypadEnter).isReturnKey)
        #expect(!makeKey(KeyCode.space).isReturnKey)
        #expect(!makeKey(KeyCode.escape).isReturnKey)
        #expect(!makeKey(KeyCode.keypadClear).isReturnKey)
    }

    @Test func escapeAndKeypadClearAreEscapeKeys() {
        #expect(makeKey(KeyCode.escape).isEscapeKey)
        #expect(makeKey(KeyCode.keypadClear).isEscapeKey)
        #expect(!makeKey(KeyCode.return).isEscapeKey)
        #expect(!makeKey(KeyCode.keypadEnter).isEscapeKey)
    }

    /// Real keypad events carry .numericPad (and often .function); the
    /// engines' `where keyEvent.isBareKey` patterns must still match.
    @Test func keypadFlagsDoNotBreakBareKey() {
        let flags: NSEvent.ModifierFlags = [.numericPad, .function]
        #expect(makeKey(KeyCode.keypadEnter, modifiers: flags).isBareKey)
        #expect(makeKey(KeyCode.keypadClear, modifiers: flags).isBareKey)
        #expect(!makeKey(KeyCode.keypadEnter, modifiers: [.command]).isBareKey)
    }

    /// The set is derived from the web-code map — pin its shape and
    /// cross-check the independently enumerated location map.
    @Test func numericPadCharacterKeysMatchTheKeyboardMapping() {
        let keys = KeyboardEventMapping.numericPadCharacterKeys
        #expect(keys.count == 17)
        #expect(!keys.contains(KeyCode.keypadEnter))
        #expect(!keys.contains(KeyCode.keypadClear))
        for keyCode in keys {
            #expect(KeyboardEventMapping.location(for: keyCode) == 3)
        }
    }

    @Test func numericPadCharacterKeyIdentifiesTheCluster() {
        #expect(makeKey(UInt16(kVK_ANSI_Keypad5)).isNumericPadCharacterKey)
        #expect(!makeKey(KeyCode.keypadEnter).isNumericPadCharacterKey)
        #expect(!makeKey(KeyCode.keypadClear).isNumericPadCharacterKey)
        #expect(!makeKey(UInt16(kVK_ANSI_5)).isNumericPadCharacterKey)
    }

    @Test func numericPadResultSwallowsWhileComposing() {
        let context = InputEngineContext()
        context.markedText = "A"
        let result = InputEngine.numericPadResult(
            for: makeKey(UInt16(kVK_ANSI_Keypad5), modifiers: [.numericPad]), context: context)
        guard case .handled(let actions)? = result else {
            Issue.record("expected .handled while composing")
            return
        }
        #expect(actions.isEmpty)
    }

    @Test func numericPadResultPassesThroughWhenIdle() {
        let result = InputEngine.numericPadResult(
            for: makeKey(UInt16(kVK_ANSI_Keypad5), modifiers: [.numericPad]),
            context: InputEngineContext())
        guard case .notHandled(let actions)? = result else {
            Issue.record("expected .notHandled when idle")
            return
        }
        #expect(actions.isEmpty)
    }

    @Test func numericPadResultLeavesModifierCombosAlone() {
        let context = InputEngineContext()
        #expect(InputEngine.numericPadResult(
            for: makeKey(UInt16(kVK_ANSI_Keypad5), modifiers: [.numericPad, .option]),
            context: context) == nil)
        #expect(InputEngine.numericPadResult(
            for: makeKey(KeyCode.keypadEnter, modifiers: [.numericPad]), context: context) == nil)
        #expect(InputEngine.numericPadResult(
            for: makeKey(UInt16(kVK_ANSI_5)), context: context) == nil)
    }
}
