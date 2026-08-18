import Testing

/// CINEngine loads its table in `load()`, not `init()`, so a bare subclass
/// with an ID exercises the confirm path without a table.
private final class StubCINEngine: CINEngine {
    override var engineID: String { "StubCIN" }
}

/// CIN's `candidateConfirmed`: it only clears the staged preview for the
/// host; the commit itself happens in the host fallback.
@MainActor
struct CINEngineConfirmTests {
    private func confirm(_ candidate: String, associating: Bool = false) -> EngineHandleResult {
        let engine = StubCINEngine()
        let context = engine.createContext()
        context.isAssociating = associating
        return engine.candidateConfirmed(
            context: context, candidate, absoluteIndex: 0, raw: nil,
            candidateWindow: visibleCandidateWindow)
    }

    @Test func confirmingACandidateClearsStagedForTheHost() {
        let result = confirm("中")
        #expect(!result.isHandled)
        #expect(markedText(result.actions)?.text == "中")
        #expect(markedText(result.actions)?.staged == 0)
    }

    @Test func confirmingWithNothingHighlightedDefersToTheHost() {
        let result = confirm("")
        #expect(!result.isHandled)
        #expect(result.actions.isEmpty)
    }

    @Test func confirmingAFollowupLeavesStagedAlone() {
        let result = confirm("文", associating: true)
        #expect(!result.isHandled)
        #expect(result.actions.isEmpty)
    }
}
