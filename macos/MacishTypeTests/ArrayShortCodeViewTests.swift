import Testing

/// The short-code slots Array previews while composing a one- or two-key code.
@MainActor
struct ArrayShortCodeViewTests {
    private let entries: [ArrayDictionary.ShortCodeEntry] = [("1", "中"), ("3", "文")]

    @Test func shortCodesKeepTheirOwnSlotsWhilePlaceholdersAreOff() {
        let view = ArrayEngine.shortCodeView(
            entries: entries, placeholders: false, highlighting: "文")
        #expect(view.indexLabels == "13")
        #expect(view.candidates.map(\.text) == ["中", "文"])
        #expect(view.highlight == 1)
    }

    @Test func placeholdersFillTheEmptySlotsWhenEnabled() {
        let view = ArrayEngine.shortCodeView(
            entries: entries, placeholders: true, highlighting: "文")
        #expect(view.indexLabels == "1234567890")
        #expect(view.candidates.count == 10)
        #expect(view.candidates[0].text == "中")
        // Slot "3" is the third label, so the Space target keeps its numbering.
        #expect(view.highlight == 2)
        let placeholders = view.candidates.filter {
            ($0.payload as? String) == ArrayEngine.placeholderPayload
        }
        #expect(placeholders.count == 8)
        #expect(placeholders.allSatisfy { $0.text == "□" })
    }

    @Test func aTargetOutsideTheShortCodesSuspendsTheHighlight() {
        let view = ArrayEngine.shortCodeView(
            entries: entries, placeholders: true, highlighting: "字")
        #expect(view.highlight == -1)
    }

    @Test func aCodeWithNoShortCodesStaysEmptyEvenWithPlaceholdersOn() {
        let view = ArrayEngine.shortCodeView(
            entries: [], placeholders: true, highlighting: "中")
        #expect(view.candidates.isEmpty)
        #expect(view.indexLabels.isEmpty)
        #expect(view.highlight == -1)
    }
}
