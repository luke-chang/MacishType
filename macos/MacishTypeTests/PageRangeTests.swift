import Testing

struct PageRangeTests {
    /// A layout mid-rebuild hands the builder anything; what comes out must
    /// still index the candidate list safely.
    @Test func clampedPageRangeStaysWithinTheCandidateList() {
        // A negative start with nothing to show.
        #expect(MacishBasePanel.clampedPageRange(start: -1, count: 9, displayCount: 0) == 0..<0)
        // A negative start while candidates exist keeps the full page.
        #expect(MacishBasePanel.clampedPageRange(start: -1, count: 9, displayCount: 5) == 0..<5)
        // A start past the end never inverts the range.
        #expect(MacishBasePanel.clampedPageRange(start: 5, count: 3, displayCount: 0) == 0..<0)
        // A short last page stops at the last candidate.
        #expect(MacishBasePanel.clampedPageRange(start: 6, count: 3, displayCount: 7) == 6..<7)
        // A full page passes through.
        #expect(MacishBasePanel.clampedPageRange(start: 0, count: 3, displayCount: 7) == 0..<3)
    }
}
