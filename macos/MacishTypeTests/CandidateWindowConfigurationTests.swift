import Testing

struct CandidateWindowConfigurationTests {
    // MARK: Index label lookup

    @Test func candidateIndexHonorsThePageSizePrefix() {
        var config = CandidateWindowConfiguration()  // "1234567890", pageSize 9
        #expect(config.candidateIndex(for: "1") == 0)
        #expect(config.candidateIndex(for: "9") == 8)
        #expect(config.candidateIndex(for: "0") == nil)  // label 10 sits past the page

        config.pageSize = 10
        #expect(config.candidateIndex(for: "0") == 9)
    }

    @Test func duplicateLabelsMatchTheirFirstOccurrence() {
        var config = CandidateWindowConfiguration()
        config.indexLabels = "aab"
        config.pageSize = 3
        #expect(config.candidateIndex(for: "a") == 0)
        #expect(config.candidateIndex(for: "b") == 2)
        #expect(config.candidateIndex(for: "z") == nil)
    }

    /// Whitespace never selects, even when a space reserves a label slot.
    @Test func whitespaceNeverSelects() {
        var config = CandidateWindowConfiguration()
        config.indexLabels = " ab"
        config.pageSize = 3
        #expect(config.candidateIndex(for: " ") == nil)
        #expect(config.candidateIndex(for: "a") == 1)
    }

    // MARK: Keystroke lookup

    /// Without the Shift requirement the keystroke form reduces to plain
    /// character matching; a shifted key just produces a different character.
    @Test func keystrokeLookupWithoutShiftRequirementMatchesByCharacter() {
        let config = CandidateWindowConfiguration()  // "1234567890", pageSize 9
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: false, option: false, character: "1") == 0)
        // Shift+1 produces "!" — no label matches, so nothing selects.
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: false, character: "!") == nil)
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: false, option: false, character: nil) == nil)
    }

    @Test func shiftRequirementMatchesPhysicalDigitsOnly() {
        var config = CandidateWindowConfiguration()
        config.indexLabelDigitsRequireShift = true
        config.pageSize = 10
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: false, character: "!") == 0)
        #expect(config.candidateIndex(
            forWebCode: "Digit9", shift: true, option: false, character: "(") == 8)
        #expect(config.candidateIndex(
            forWebCode: "Digit0", shift: true, option: false, character: ")") == 9)
        // Without Shift the digit stays with the engine / client.
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: false, option: false, character: "1") == nil)
        // A non-digit key never selects, whatever character it produces.
        #expect(config.candidateIndex(
            forWebCode: "KeyA", shift: true, option: false, character: "A") == nil)
    }

    @Test func shiftRequirementHonorsThePageSizePrefix() {
        var config = CandidateWindowConfiguration()  // pageSize 9
        config.indexLabelDigitsRequireShift = true
        #expect(config.candidateIndex(
            forWebCode: "Digit0", shift: true, option: false, character: ")") == nil)
    }

    @Test func optionNeverSelects() {
        var config = CandidateWindowConfiguration()
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: false, option: true, character: "1") == nil)
        config.indexLabelDigitsRequireShift = true
        config.pageSize = 10
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: true, character: "!") == nil)
    }

    /// Unknown or empty codes degrade to character matching (parity with
    /// the QuickJS glue).
    @Test func unknownCodesDegradeToCharacterMatching() {
        var config = CandidateWindowConfiguration()
        #expect(config.candidateIndex(
            forWebCode: "", shift: false, option: false, character: "1") == 0)
        config.indexLabelDigitsRequireShift = true
        config.indexLabels = "a1b2"
        config.pageSize = 4
        #expect(config.candidateIndex(
            forWebCode: "", shift: false, option: false, character: "a") == 0)
    }

    /// Matching is by label content, not key position: each digit key
    /// selects the position where its digit appears in the labels.
    @Test func shiftedDigitsFollowTheLabelOrder() {
        var config = CandidateWindowConfiguration()
        config.indexLabelDigitsRequireShift = true
        config.indexLabels = "01234"
        config.pageSize = 5
        #expect(config.candidateIndex(
            forWebCode: "Digit0", shift: true, option: false, character: ")") == 0)
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: false, character: "!") == 1)
        #expect(config.candidateIndex(
            forWebCode: "Digit5", shift: true, option: false, character: "%") == nil)
    }

    @Test func keypadDigitsSelectWithShift() {
        var config = CandidateWindowConfiguration()
        config.indexLabelDigitsRequireShift = true
        config.pageSize = 10
        #expect(config.candidateIndex(
            forWebCode: "Numpad1", shift: true, option: false, character: "1") == 0)
        #expect(config.candidateIndex(
            forWebCode: "Numpad1", shift: false, option: false, character: "1") == nil)
    }

    /// Non-digit labels keep plain character selection under the digit
    /// Shift requirement; digit characters from non-digit keys never select.
    @Test func nonDigitLabelsIgnoreTheShiftRequirement() {
        var config = CandidateWindowConfiguration()
        config.indexLabelDigitsRequireShift = true
        config.indexLabels = "a1b2"
        config.pageSize = 4
        #expect(config.candidateIndex(
            forWebCode: "KeyA", shift: false, option: false, character: "a") == 0)
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: false, character: "!") == 1)
        #expect(config.candidateIndex(
            forWebCode: "KeyA", shift: false, option: false, character: "1") == nil)
    }

    @Test func missingAndEmptyLabelsNeverMatch() {
        var config = CandidateWindowConfiguration()
        config.indexLabelDigitsRequireShift = true
        config.pageSize = 10
        config.indexLabels = " 234567890"
        #expect(config.candidateIndex(
            forWebCode: "Digit1", shift: true, option: false, character: "!") == nil)
        #expect(config.candidateIndex(
            forWebCode: "Digit2", shift: true, option: false, character: "@") == 1)
        config.indexLabels = ""
        #expect(config.candidateIndex(
            forWebCode: "Digit2", shift: true, option: false, character: "@") == nil)
    }

    // MARK: Navigation intent

    @Test func tabNavigatesItemsWithWrapping() throws {
        let config = CandidateWindowConfiguration()
        let forward = try #require(config.navigationIntent(
            keyCode: KeyCode.tab, shift: false, option: false))
        #expect(forward.direction == .itemForward && forward.wrapping)

        let backward = try #require(config.navigationIntent(
            keyCode: KeyCode.tab, shift: true, option: false))
        #expect(backward.direction == .itemBackward && backward.wrapping)
    }

    @Test func plainNavigationKeysMapWithoutWrapping() throws {
        let config = CandidateWindowConfiguration()
        let expected: [(UInt16, NavigationDirection)] = [
            (KeyCode.leftArrow, .left), (KeyCode.rightArrow, .right),
            (KeyCode.downArrow, .down), (KeyCode.upArrow, .up),
            (KeyCode.pageUp, .pageUp), (KeyCode.pageDown, .pageDown),
            (KeyCode.home, .home), (KeyCode.end, .end),
        ]
        for (keyCode, direction) in expected {
            let intent = try #require(config.navigationIntent(
                keyCode: keyCode, shift: false, option: false))
            #expect(intent.direction == direction)
            #expect(!intent.wrapping)
        }
    }

    /// Option always leaves the key to the engine; Shift does too on
    /// everything except Tab.
    @Test func modifiersDisqualifyNavigation() {
        let config = CandidateWindowConfiguration()
        #expect(config.navigationIntent(keyCode: KeyCode.tab, shift: false, option: true) == nil)
        #expect(config.navigationIntent(keyCode: KeyCode.leftArrow, shift: true, option: false) == nil)
        #expect(config.navigationIntent(keyCode: KeyCode.pageDown, shift: true, option: false) == nil)
    }

    @Test func nonNavigationKeysYieldNoIntent() {
        let config = CandidateWindowConfiguration()
        #expect(config.navigationIntent(keyCode: 0, shift: false, option: false) == nil)
        #expect(config.navigationIntent(keyCode: KeyCode.space, shift: false, option: false) == nil)
    }

    // MARK: Validators

    @Test func pageSizeBoundsAreClosed() {
        #expect(!CandidateWindowConfiguration.isValidPageSize(0))
        #expect(CandidateWindowConfiguration.isValidPageSize(1))
        #expect(CandidateWindowConfiguration.isValidPageSize(11))
        #expect(!CandidateWindowConfiguration.isValidPageSize(12))
    }

    @Test func indexLabelsMustBeSingleASCIIPrintableScalars() {
        #expect(CandidateWindowConfiguration.isValidIndexLabels("123abc"))
        #expect(CandidateWindowConfiguration.isValidIndexLabels(" "))    // space reserves a slot
        #expect(CandidateWindowConfiguration.isValidIndexLabels(""))     // collapses the column
        #expect(!CandidateWindowConfiguration.isValidIndexLabels("\t"))
        #expect(!CandidateWindowConfiguration.isValidIndexLabels("中"))
        #expect(!CandidateWindowConfiguration.isValidIndexLabels("e\u{301}"))  // combining pair
    }
}
