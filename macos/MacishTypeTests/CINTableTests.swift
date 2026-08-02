import Foundation
import Testing

struct CINTableTests {
    private func write(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cin-test-\(UUID().uuidString).cin")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeTable(_ content: String) throws -> CINTable {
        let url = try write(content)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(CINTable(contentsOf: url))
    }

    // MARK: Directive matrix

    @Test func directivesPopulateTableMetadata() throws {
        let table = try makeTable("""
            # leading comment
            %ename Alpha
            %cname 甲表
            %selkey asdf
            %endkey ;'
            %keyname begin
            a 日
            b 月
            %keyname end
            %chardef begin
            a 一
            ab 二
            %chardef end
            """)
        #expect(table.ename == "Alpha")
        #expect(table.cname == "甲表")
        #expect(table.selkey == "asdf")
        #expect(table.indexLabels == "asdf")
        #expect(table.pageSize == 4)
        #expect(table.isEndKey(";") && table.isEndKey("'"))
        #expect(!table.isEndKey("a"))
        #expect(table.rootDisplay("ab") == "日月")
        #expect(table.rootDisplay("ax") == "日x")  // unmapped key falls back raw
        #expect(table.maxCodeLength == 2)
        #expect(table.isCodeKey("a") && table.isCodeKey("b"))
        #expect(!table.isCodeKey("z"))
    }

    @Test func selkeyDefaultsWhenAbsent() throws {
        let table = try makeTable("%chardef begin\na 一\n%chardef end")
        #expect(table.selkey == "123456789")
        #expect(table.pageSize == 9)
    }

    /// Directives are only honored between sections; the same tokens
    /// inside a chardef block are noise, not entries or settings.
    @Test func directivesInsideChardefAreIgnored() throws {
        let table = try makeTable("""
            %chardef begin
            %selkey asdf
            a 一
            %chardef end
            """)
        #expect(table.selkey == "123456789")
        #expect(table.lookup("%selkey").isEmpty)
    }

    @Test func unknownDirectivesAreIgnored() throws {
        let table = try makeTable("""
            %gen_inp
            %space_style 4
            %chardef begin
            a 一
            %chardef end
            """)
        #expect(table.lookup("a") == ["一"])
    }

    @Test func caseFoldsUnlessKeepKeyCase() throws {
        let folded = try makeTable("%chardef begin\nAB 一\n%chardef end")
        #expect(!folded.keepKeyCase)
        #expect(folded.lookup("ab") == ["一"])
        #expect(folded.lookup("AB") == ["一"])  // input normalized too

        let kept = try makeTable("%keep_key_case\n%chardef begin\nAb 一\nab 二\n%chardef end")
        #expect(kept.keepKeyCase)
        #expect(kept.lookup("Ab") == ["一"])
        #expect(kept.lookup("ab") == ["二"])
    }

    @Test func multilingualEnameResolvesToTraditionalChinese() throws {
        let table = try makeTable("%ename Alpha:en;甲:zh;\n%chardef begin\na 一\n%chardef end")
        #expect(table.ename == "甲")
    }

    @Test func duplicateCodesKeepFileOrder() throws {
        let table = try makeTable("%chardef begin\naa 一\naa 二\nab 三\n%chardef end")
        #expect(table.lookup("aa") == ["一", "二"])
        #expect(table.lookup("ac").isEmpty)
    }

    @Test func representativeMarkerIsStripped() throws {
        let table = try makeTable("%chardef begin\naa *一\n%chardef end")
        #expect(table.lookup("aa") == ["一"])
    }

    @Test func fullWidthSpaceSurvivesAsCandidate() throws {
        let table = try makeTable("%chardef begin\nsp \u{3000}\n%chardef end")
        #expect(table.lookup("sp") == ["\u{3000}"])
    }

    @Test func tableWithoutChardefFailsInit() throws {
        let url = try write("%ename Alpha\n%keyname begin\na 日\n%keyname end\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CINTable(contentsOf: url) == nil)
    }

    // MARK: Line endings

    @Test func crlfParsesIdenticallyToLF() throws {
        let lines = [
            "%ename Alpha", "%selkey asdf",
            "%chardef begin", "a 一", "ab 二", "%chardef end",
        ]
        let lf = try makeTable(lines.joined(separator: "\n"))
        let crlf = try makeTable(lines.joined(separator: "\r\n"))
        #expect(crlf.ename == lf.ename)
        #expect(crlf.selkey == lf.selkey)
        #expect(crlf.lookup("a") == lf.lookup("a"))
        #expect(crlf.lookup("ab") == lf.lookup("ab"))
        #expect(crlf.maxCodeLength == lf.maxCodeLength)
    }

    // MARK: Previewability

    @Test func extensionViaNonSelkeyStaysPreviewable() throws {
        let table = try makeTable("%chardef begin\na 一\nab 二\n%chardef end")
        #expect(table.isPreviewable)
    }

    @Test func selkeyExtensionOfACompleteCodeBreaksPreview() throws {
        let table = try makeTable("%chardef begin\na 一\na1 二\n%chardef end")
        #expect(!table.isPreviewable)
    }

    /// The ambiguous continuation only needs the selkey char as a code
    /// prefix, not a complete code.
    @Test func selkeyPrefixExtensionAlsoBreaksPreview() throws {
        let table = try makeTable("%chardef begin\na 一\na12 二\n%chardef end")
        #expect(!table.isPreviewable)
    }

    /// Same codes, opposite verdicts — only the selkey decides.
    @Test func previewabilityFollowsTheSelkey() throws {
        let chardef = "%chardef begin\na 一\nax 二\n%chardef end"
        let ambiguous = try makeTable("%selkey xyz\n" + chardef)
        #expect(!ambiguous.isPreviewable)
        let safe = try makeTable("%selkey 123\n" + chardef)
        #expect(safe.isPreviewable)
    }
}
