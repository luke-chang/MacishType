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
