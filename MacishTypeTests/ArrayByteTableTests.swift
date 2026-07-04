import Foundation
import Testing

/// The build step delivers code-sorted lines, so every fixture here is
/// pre-sorted by code bytes; the table itself never sorts.
struct ArrayByteTableTests {
    private func makeTable(_ lines: [String]) -> ArrayByteTable {
        ArrayByteTable(bytes: Array(lines.joined(separator: "\n").utf8))
    }

    @Test func emptyInputYieldsNoMatches() {
        let table = ArrayByteTable(bytes: [])
        #expect(table.lookup("a").isEmpty)
    }

    @Test func exactLookupAtBothEndsOfTheEntryArray() {
        let table = makeTable(["a\t一", "ab\t二", "b\t三"])
        #expect(table.lookup("a") == ["一"])   // first entry
        #expect(table.lookup("b") == ["三"])   // last entry
    }

    @Test func missesBelowBetweenAndAboveTheRange() {
        let table = makeTable(["b\t一", "d\t二"])
        #expect(table.lookup("a").isEmpty)  // below the first code
        #expect(table.lookup("c").isEmpty)  // gap between codes
        #expect(table.lookup("e").isEmpty)  // above the last code
    }

    /// Length participates in ordering after shared bytes: a probe that
    /// is a prefix (or an extension) of a stored code must not match.
    @Test func prefixRelationsAreNotExactMatches() {
        let table = makeTable(["ab\t一"])
        #expect(table.lookup("a").isEmpty)
        #expect(table.lookup("abc").isEmpty)
        #expect(table.lookup("ab") == ["一"])
    }

    @Test func duplicateCodesReturnAllValuesInFileOrder() {
        let table = makeTable(["a\t一", "a\t二", "a\t三", "b\t四"])
        #expect(table.lookup("a") == ["一", "二", "三"])
    }

    @Test func parserSkipsNoiseAndHandlesCRLF() {
        let content = "# comment\r\n\r\nnotab\r\na\t一\r\nb\t\r\nc\t二\tignored"
        let table = ArrayByteTable(bytes: Array(content.utf8))
        #expect(table.lookup("a") == ["一"])
        #expect(table.lookup("b").isEmpty)      // empty value line dropped
        #expect(table.lookup("c") == ["二"])    // third field ignored
        #expect(table.lookup("notab").isEmpty)  // tabless line dropped
    }

    @Test func lastLineWithoutTrailingNewlineIsParsed() {
        let table = ArrayByteTable(bytes: Array("a\t一\nb\t二".utf8))
        #expect(table.lookup("b") == ["二"])
    }

    @Test func matchingEnumerationVisitsUniqueCodesInOrder() {
        let table = makeTable(["a\t一", "a\t二", "ab\t三", "b\t四"])
        var visited = [(String, [String])]()
        table.forEachMatchingCode(where: { _, range in range.count == 1 }) {
            visited.append(($0, $1))
        }
        #expect(visited.count == 2)
        #expect(visited[0].0 == "a")
        #expect(visited[0].1 == ["一", "二"])
        #expect(visited[1].0 == "b")
        #expect(visited[1].1 == ["四"])
    }
}
