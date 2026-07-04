import Testing

/// Smoke test proving app sources compile and link into the test
/// bundle; real suites live in dedicated files per subject.
struct MacishTypeTests {
    @Test func keyboardMappingRoundTrip() {
        let keyCode: UInt16 = 0  // ANSI A
        let webCode = KeyboardEventMapping.webCode(for: keyCode)
        #expect(webCode == "KeyA")
        #expect(KeyboardEventMapping.keyCode(forWebCode: webCode) == keyCode)
    }
}
