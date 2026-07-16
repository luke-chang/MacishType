import AppKit
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
}
