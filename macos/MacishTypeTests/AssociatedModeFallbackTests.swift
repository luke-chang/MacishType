import Testing

/// InputEngine is abstract and `init()` → `reloadConfig()` reads `engineID`,
/// so a test double must supply one. The dictionary is stubbed to keep the
/// fallback independent of the bundled AssociatedDictionary.
private final class StubEngine: InputEngine {
    override var engineID: String { "StubAssoc" }
    var lookups: [Character] = []
    var followups: [Character: [String]] = [:]

    override func lookupAssociatedCandidates(for char: Character) -> [String] {
        lookups.append(char)
        return followups[char] ?? []
    }
}

/// The host default for `candidateConfirmed`: what it commits, and when it
/// hands the composition over to associated mode.
@MainActor
struct AssociatedModeFallbackTests {
    private func makeEngine(
        associatedMode: Bool = true, followups: [Character: [String]] = [:]
    ) -> StubEngine {
        let engine = StubEngine()
        engine.enableAssociatedMode = associatedMode
        engine.followups = followups
        return engine
    }

    private func confirm(
        _ engine: StubEngine, _ candidate: String,
        staged: String = "", associating: Bool = false
    ) -> [EngineAction] {
        let context = InputEngineContext()
        context.stagedText = staged
        context.isAssociating = associating
        return engine.candidateConfirmedFallback(
            context: context, candidate, absoluteIndex: 0, raw: nil,
            candidateWindow: visibleCandidateWindow)
    }

    // MARK: Empty commits

    @Test func emptyCommitFlushesWhatIsStaged() {
        let engine = makeEngine(followups: ["中": ["文"]])
        #expect(flushedText(confirm(engine, "", staged: "中")) == "")
        #expect(engine.lookups.isEmpty)
    }

    @Test func emptyCommitInAssociatedModeFlushesTheHeldText() {
        let engine = makeEngine(followups: ["中": ["文"]])
        #expect(flushedText(confirm(engine, "", staged: "甲中", associating: true)) == "")
    }

    // MARK: Entering associated mode

    @Test func aSingleCharacterWithFollowupsEntersAssociatedMode() {
        let engine = makeEngine(followups: ["中": ["文", "國"]])
        let result = associatedMode(confirm(engine, "中"))
        #expect(result?.held == "中")
        #expect(result?.candidates == ["文", "國"])
    }

    @Test func theStagedPrefixFoldsIntoTheHeldText() {
        let engine = makeEngine(followups: ["中": ["文"]])
        #expect(associatedMode(confirm(engine, "中", staged: "甲"))?.held == "甲中")
    }

    @Test func theDictionaryIsKeyedByTheHeldTextsLastCharacter() {
        let engine = makeEngine(followups: ["中": ["文"]])
        _ = confirm(engine, "中", staged: "甲")
        #expect(engine.lookups == ["中"])
    }

    /// No follow-ups still routes through `.enterAssociatedMode`; the empty
    /// payload is what makes the Controller commit the accumulated text.
    @Test func aCandidateWithoutFollowupsCarriesAnEmptyPayload() {
        let engine = makeEngine()
        let result = associatedMode(confirm(engine, "中", staged: "甲"))
        #expect(result?.held == "甲中")
        #expect(result?.candidates.isEmpty == true)
    }

    // MARK: Staying out of associated mode

    @Test func multiCharacterCandidatesNeverEnterAssociatedMode() {
        let engine = makeEngine(followups: ["中": ["文"]])
        #expect(flushedText(confirm(engine, "中文")) == "中文")
        #expect(engine.lookups.isEmpty)
    }

    @Test func theSettingGatesTheLookup() {
        let engine = makeEngine(associatedMode: false, followups: ["中": ["文"]])
        #expect(flushedText(confirm(engine, "中")) == "中")
        #expect(engine.lookups.isEmpty)
    }

    @Test func confirmingInAssociatedModeFlushesHeldPlusFollowup() {
        let engine = makeEngine(followups: ["文": ["章"]])
        #expect(flushedText(confirm(engine, "文", staged: "中", associating: true)) == "文")
    }
}
