import AppKit
import Testing

/// Array's feedback for input that leads nowhere: the alert sound, and a
/// cleared code when a selection key selects nothing.
///
/// The test bundle stages no code tables, so every lookup misses — which is
/// the "nothing to select" state these paths report. Cases that need a miss
/// also use a code the main table has no entry for.
@MainActor
struct ArrayEngineErrorFeedbackTests {
    /// Sends one keystroke, identified by its W3C physical position and the
    /// characters it types, to an engine composing `code`. A fresh instance
    /// rather than `ArrayEngine.shared`: `load()` installs a font-coverage
    /// observer that `unload()` takes back down.
    private func press(
        _ webCode: String, _ characters: String, composing code: String
    ) -> (result: EngineHandleResult, context: ArrayEngineContext) {
        let engine = ArrayEngine()
        engine.load()
        defer { engine.unload() }
        let context = engine.createContext() as! ArrayEngineContext
        context.code = code
        let keyEvent = KeyEventInput(
            keyCode: KeyboardEventMapping.keyCode(forWebCode: webCode) ?? 0,
            characters: characters, charactersIgnoringModifiers: characters,
            modifiers: [], isRepeat: false)
        let result = engine.handleKey(
            context: context, keyEvent: keyEvent, candidateWindow: visibleCandidateWindow)
        return (result, context)
    }

    // MARK: Selection keys with no candidate behind them

    @Test func aDigitThatSelectsNothingRestartsTheComposition() {
        let (result, _) = press("Digit3", "3", composing: "a")
        #expect(result.isHandled)
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
    }

    @Test func aKeypadDigitThatSelectsNothingRestartsItToo() {
        let (result, _) = press("Numpad3", "3", composing: "a")
        #expect(result.isHandled)
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
    }

    @Test func aDigitWhileIdleReachesTheClient() {
        let (result, _) = press("Digit3", "3", composing: "")
        #expect(!result.isHandled)
        #expect(result.actions.isEmpty)
    }

    // MARK: Codes that cannot grow

    @Test func aFifthKeyOtherThanTheDisambiguationKeyBeeps() {
        let (result, context) = press("KeyA", "a", composing: "aaaa")
        #expect(beeped(result.actions))
        #expect(context.code == "aaaa")
    }

    @Test func extendingAFullWildcardCodeBeeps() {
        let (result, context) = press("KeyA", "a", composing: "a?aaa")
        #expect(beeped(result.actions))
        #expect(context.code == "a?aaa")
    }

    // MARK: Lookups that find nothing

    @Test func spaceWithNothingToSelectBeepsAndClears() {
        let (result, _) = press("Space", " ", composing: "iiii")
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
    }

    @Test func aPhraseLookupThatFindsNothingBeeps() {
        let (result, _) = press("Quote", "'", composing: "iiii")
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
    }
}
