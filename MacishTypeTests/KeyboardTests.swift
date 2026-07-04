import Testing

struct KeyboardEventMappingTests {
    /// Every keyCode with a web code must map back to itself, and the
    /// table must stay near its known size so a gutted mapping fails.
    @Test func webCodeRoundTripsForAllMappedKeyCodes() {
        var mappedCount = 0
        for keyCode in UInt16(0)...200 {
            let webCode = KeyboardEventMapping.webCode(for: keyCode)
            guard !webCode.isEmpty else { continue }
            mappedCount += 1
            #expect(KeyboardEventMapping.keyCode(forWebCode: webCode) == keyCode)
        }
        #expect(mappedCount >= 100)
    }

    @Test func unknownCodesMapToNothing() {
        #expect(KeyboardEventMapping.webCode(for: 200) == "")
        #expect(KeyboardEventMapping.keyCode(forWebCode: "") == nil)
        #expect(KeyboardEventMapping.keyCode(forWebCode: "NoSuchCode") == nil)
    }

    @Test func namedKeysWinOverCharacters() {
        #expect(KeyboardEventMapping.webKey(for: 36, characters: "\r") == "Enter")
        #expect(KeyboardEventMapping.webKey(for: 49, characters: "x") == " ")
    }

    @Test func characterKeysFallThroughToCharacters() {
        #expect(KeyboardEventMapping.webKey(for: 0, characters: "a") == "a")
        // Numpad digits carry no named key; the characters tier answers.
        #expect(KeyboardEventMapping.webKey(for: 82, characters: "0") == "0")
        #expect(KeyboardEventMapping.webKey(for: 0, characters: nil) == "Unidentified")
        #expect(KeyboardEventMapping.webKey(for: 0, characters: "") == "Unidentified")
    }

    /// Keypad Clear sits where NumLock lives on PC keyboards: its W3C
    /// code is "NumLock" while its key stays "Clear".
    @Test func keypadClearFollowsW3CSplit() {
        #expect(KeyboardEventMapping.webCode(for: 71) == "NumLock")
        #expect(KeyboardEventMapping.webKey(for: 71, characters: nil) == "Clear")
        #expect(KeyboardEventMapping.location(for: 71) == 3)
    }

    @Test func numpadEnterSharesKeyWithMainEnter() {
        #expect(KeyboardEventMapping.webCode(for: 76) == "NumpadEnter")
        #expect(KeyboardEventMapping.webKey(for: 76, characters: nil) == "Enter")
        #expect(KeyboardEventMapping.location(for: 76) == 3)
    }

    @Test func locationsDistinguishSides() {
        #expect(KeyboardEventMapping.location(for: 56) == 1)  // ShiftLeft
        #expect(KeyboardEventMapping.location(for: 60) == 2)  // ShiftRight
        #expect(KeyboardEventMapping.location(for: 82) == 3)  // Numpad0
        #expect(KeyboardEventMapping.location(for: 0) == 0)   // KeyA
    }
}
