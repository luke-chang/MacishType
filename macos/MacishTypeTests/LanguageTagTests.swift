import Testing

struct LanguageTagTests {
    @Test func scriptImpliedByTheRegionIsDropped() {
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hant-TW") == "zh-TW")
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hant-HK") == "zh-HK")
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hans-CN") == "zh-CN")
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hans-SG") == "zh-SG")
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hans") == "zh")
    }

    /// Dropping these would hand the user the other script.
    @Test func scriptTheRegionContradictsIsKept() {
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hans-HK") == "zh-Hans-HK")
        #expect(JavaScriptEngine.normalizeBCP47("zh-Hant") == "zh-Hant")
        #expect(JavaScriptEngine.normalizeBCP47("sr-Latn-RS") == "sr-Latn-RS")
    }

    @Test func tagsWithoutAScriptPassThrough() {
        #expect(JavaScriptEngine.normalizeBCP47("en-US") == "en-US")
        #expect(JavaScriptEngine.normalizeBCP47("es-419") == "es-419")
        #expect(JavaScriptEngine.normalizeBCP47("ja") == "ja")
    }

    /// A secondary preference loses the region the system tacked on, but not
    /// the script that region was implying.
    @Test func autoTaggedRegionComesOffWithoutTheScript() {
        #expect(JavaScriptEngine.languagesForJS(preferred: ["en-TW", "zh-Hant-TW"], userRegion: "TW")
            == ["en-TW", "en", "zh-Hant", "zh"])
        #expect(JavaScriptEngine.languagesForJS(preferred: ["ja-JP", "zh-Hant-HK"], userRegion: "HK")
            == ["ja-JP", "ja", "zh-Hant", "zh"])
    }

    @Test func primaryPreferenceKeepsItsRegion() {
        #expect(JavaScriptEngine.languagesForJS(preferred: ["zh-Hant-TW", "en-TW"], userRegion: "TW")
            == ["zh-TW", "zh", "en"])
    }
}
