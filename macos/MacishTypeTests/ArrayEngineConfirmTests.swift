import Testing

/// Array's candidate window callbacks, which mirror the JS reference engine.
/// `candidateConfirmed` only decides what the host should do next; the commit
/// itself happens in the host fallback (see AssociatedModeFallbackTests).
@MainActor
struct ArrayEngineConfirmTests {
    private func confirm(
        _ candidate: String, associating: Bool = false, groupMenu: Bool = false,
        raw: Candidate? = nil
    ) -> EngineHandleResult {
        let engine = ArrayEngine.shared
        let context = engine.createContext() as! ArrayEngineContext
        context.isAssociating = associating
        context.groupMenu = groupMenu
        return engine.candidateConfirmed(
            context: context, candidate, absoluteIndex: 0, raw: raw,
            candidateWindow: visibleCandidateWindow)
    }

    @Test func confirmingWithNothingHighlightedDoesNothing() {
        let result = confirm("")
        #expect(result.isHandled)
        #expect(result.actions.isEmpty)
    }

    @Test func confirmingWithNothingHighlightedDefersToTheHostWhenAssociating() {
        let result = confirm("", associating: true)
        #expect(!result.isHandled)
        #expect(result.actions.isEmpty)
    }

    @Test func confirmingACandidateClearsStagedForTheHost() {
        let result = confirm("中")
        #expect(!result.isHandled)
        #expect(markedText(result.actions)?.text == "中")
        #expect(markedText(result.actions)?.staged == 0)
    }

    @Test func confirmingAFollowupLeavesStagedAlone() {
        let result = confirm("文", associating: true)
        #expect(!result.isHandled)
        #expect(result.actions.isEmpty)
    }

    @Test func confirmingAPlaceholderBeepsInsteadOfCommitting() {
        let result = confirm(
            "□", raw: Candidate("□", payload: ArrayEngine.placeholderPayload))
        #expect(result.isHandled)
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
        #expect(result.actions.count == 2)
    }

    @Test func openingASymbolGroupWithNothingRenderableBeeps() {
        let result = confirm(
            "注音符號組", groupMenu: true, raw: Candidate("注音符號組", payload: "w0"))
        #expect(result.isHandled)
        #expect(beeped(result.actions))
        #expect(resetsContext(result.actions))
    }

    // MARK: Selection change

    private func selectionChanged(_ candidate: String, selecting: Bool) -> EngineHandleResult {
        let engine = ArrayEngine.shared
        let context = engine.createContext() as! ArrayEngineContext
        context.selecting = selecting
        return engine.candidateSelectionChanged(
            context: context, candidate, absoluteIndex: 0,
            raw: Candidate(candidate), candidateWindow: visibleCandidateWindow)
    }

    @Test func highlightingWhileSelectingStagesThePreview() {
        let result = selectionChanged("中", selecting: true)
        #expect(result.isHandled)
        #expect(markedText(result.actions)?.text == "中")
        #expect(markedText(result.actions)?.staged == -1)
    }

    @Test func highlightingOutsideSelectingLeavesTheMarkedTextAlone() {
        let result = selectionChanged("中", selecting: false)
        #expect(result.isHandled)
        #expect(result.actions.isEmpty)
    }
}
