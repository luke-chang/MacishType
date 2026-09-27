import Foundation
import Testing

private typealias Manifest = JavaScriptEngine.Manifest
private typealias JSONValue = JavaScriptEngine.JSONValue

struct ManifestTests {
    private func decode(_ json: String) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }

    private func fields(_ manifest: Manifest) -> [Manifest.SettingsField] {
        (manifest.settings ?? []).flatMap(\.fields)
    }

    // MARK: Top-level tolerance

    @Test func entryIsTheOnlyHardRequirement() throws {
        #expect(throws: DecodingError.self) { _ = try decode("{}") }
        #expect(throws: DecodingError.self) { _ = try decode(#"{"entry": 5}"#) }

        let minimal = try decode(#"{"entry": "index.js"}"#)
        #expect(minimal.entry == "index.js")
        #expect(minimal.name == nil && minimal.settings == nil)
    }

    @Test func brokenSubtreesDropWithoutFailingTheManifest() throws {
        let manifest = try decode("""
            {"entry": "index.js", "name": 42, "candidateWindow": "big",
             "modules": [], "settings": "none"}
            """)
        #expect(manifest.entry == "index.js")
        #expect(manifest.name == nil)
        #expect(manifest.candidateWindow == nil)
        #expect(manifest.modules == nil)
        #expect(manifest.settings == nil)
    }

    @Test func intendedLanguageNormalizesWhitespaceToNil() throws {
        #expect(try decode(#"{"entry": "e", "intendedLanguage": "  "}"#).intendedLanguage == nil)
        #expect(try decode(#"{"entry": "e", "intendedLanguage": " zh-Hant "}"#).intendedLanguage == "zh-Hant")
        #expect(try decode(#"{"entry": "e"}"#).intendedLanguage == nil)
    }

    @Test func candidateWindowValidatesPerFieldAndKeepsTheRest() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {
                "pageSize": 99, "indexLabels": "中文",
                "fontSize": "big", "expandable": false}}
            """)
        let overrides = try #require(manifest.candidateWindow)
        #expect(overrides.pageSize == nil)      // out of 1...11
        #expect(overrides.indexLabels == nil)   // non-ASCII-printable
        #expect(overrides.fontSize == nil)      // type mismatch
        #expect(overrides.expandable == false)  // valid neighbor survives
    }

    // MARK: candidateWindow.macish

    @Test func macishSectionDecodesItsFiveFields() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {"pageSize": 10, "macish": {
                "expandable": false, "horizontalMaxVisibleRows": 4,
                "widerExpandedColumns": false, "moveOnExpand": true,
                "verticalMinVisibleRows": 3}}}
            """)
        let overrides = try #require(manifest.candidateWindow)
        let section = try #require(overrides.macish)
        #expect(section.expandable == false)
        #expect(section.horizontalMaxVisibleRows == 4)
        #expect(section.widerExpandedColumns == false)
        #expect(section.moveOnExpand == true)
        #expect(section.verticalMinVisibleRows == 3)
        #expect(overrides.pageSize == 10)
        #expect(overrides.expandable == nil)  // decoding alone does not flatten
    }

    @Test func macishSectionValidatesPerFieldAndKeepsTheRest() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {"pageSize": 10, "macish": {
                "expandable": "no", "horizontalMaxVisibleRows": 4}}}
            """)
        let overrides = try #require(manifest.candidateWindow)
        #expect(overrides.macish?.expandable == nil)             // type mismatch
        #expect(overrides.macish?.horizontalMaxVisibleRows == 4) // valid neighbor survives
        #expect(overrides.pageSize == 10)                        // flat sibling untouched
    }

    @Test func wrongShapedMacishSectionDropsOnlyItself() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {
                "pageSize": 10, "expandable": false, "macish": "yes"}}
            """)
        let overrides = try #require(manifest.candidateWindow)
        #expect(overrides.macish == nil)
        #expect(overrides.pageSize == 10)
        #expect(overrides.expandable == false)
    }

    @Test func flatteningForMacishLetsTheSectionWin() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {
                "expandable": true, "horizontalMaxVisibleRows": 3,
                "macish": {"expandable": false, "verticalMinVisibleRows": 2}}}
            """)
        let flat = try #require(manifest.candidateWindow).flattened(for: .macish)
        #expect(flat.expandable == false)            // the section wins
        #expect(flat.horizontalMaxVisibleRows == 3)  // flat kept where the section is silent
        #expect(flat.verticalMinVisibleRows == 2)
        #expect(flat.macish == nil)                  // no section reaches the cache
    }

    @Test func flatteningWithoutASectionLeavesFlatFieldsUntouched() throws {
        let manifest = try decode("""
            {"entry": "e", "candidateWindow": {"expandable": false, "pageSize": 10}}
            """)
        let flat = try #require(manifest.candidateWindow).flattened(for: .macish)
        #expect(flat.expandable == false)
        #expect(flat.pageSize == 10)
        #expect(flat.macish == nil)
    }

    /// The other half of the per-implementation rule: only these reach the
    /// `manifest.candidateWindow` proxy. Key order is host-specific and
    /// deliberately unasserted.
    @Test func theProxyVocabularyIsTheSharedFieldsOnly() {
        #expect(Set(JavaScriptEngine.candidateWindowFieldNames) == [
            "layoutDirection", "fontSize", "indexLabels", "pageSize",
            "handleNavigationKeys", "handleIndexLabelKeys",
            "indexLabelDigitsRequireShift", "associatedModeIndexLabels",
        ])
    }

    @Test func modulesListOnlyExplicitlyEnabledNames() throws {
        let manifest = try decode("""
            {"entry": "e", "modules": {
                "fontCoverage": true, "symbolNames": "yes", "wordFrequency": false}}
            """)
        #expect(manifest.modules?.enabledNames == ["fontCoverage"])
    }

    // MARK: Capabilities

    @Test func capabilitiesDecodeReverseLookupAndFullwidthInput() throws {
        let both = try decode(#"{"entry": "e", "capabilities": {"reverseLookup": true, "fullwidthInput": true}}"#)
        #expect(both.capabilities?.reverseLookup == true)
        #expect(both.capabilities?.fullwidthInput == true)

        let off = try decode(#"{"entry": "e", "capabilities": {"fullwidthInput": false}}"#)
        #expect(off.capabilities?.fullwidthInput == false)
        #expect(off.capabilities?.reverseLookup == nil)

        #expect(try decode(#"{"entry": "e"}"#).capabilities?.fullwidthInput == nil)
    }

    @Test func capabilitiesTolerateABrokenKeyWithoutDroppingNeighbors() throws {
        // Per-key tolerant decoding: a type-mismatched flag drops only itself.
        let manifest = try decode(#"{"entry": "e", "capabilities": {"reverseLookup": true, "fullwidthInput": "yes"}}"#)
        #expect(manifest.capabilities?.reverseLookup == true)
        #expect(manifest.capabilities?.fullwidthInput == nil)
    }

    // MARK: Settings tolerance and dedupe

    @Test func duplicateFieldKeysKeepTheFirstDeclaration() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [
                {"title": "A", "fields": [
                    {"type": "toggle", "key": "x", "label": "X", "default": true},
                    {"type": "number", "key": "x", "label": "X2", "default": 1}]},
                {"title": "B", "fields": [
                    {"type": "toggle", "key": "x", "label": "X3", "default": false},
                    {"type": "toggle", "key": "y", "label": "Y", "default": false}]}
            ]}
            """)
        let sections = try #require(manifest.settings)
        #expect(sections[0].fields.map(\.key) == ["x"])
        #expect(sections[1].fields.map(\.key) == ["y"])
        guard case .toggle(let survivor) = sections[0].fields[0] else {
            Issue.record("first declaration should survive as the toggle")
            return
        }
        #expect(survivor.default == true)
    }

    @Test func brokenSectionsAndFieldsDropIndividually() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [
                {"fields": []},
                {"title": "OK", "fields": [
                    {"type": "bogus", "key": "a", "label": "A"},
                    {"type": "toggle", "key": "b", "label": "B", "default": false},
                    {"type": "number", "key": "c", "label": "C"}]},
                42
            ]}
            """)
        let sections = try #require(manifest.settings)
        #expect(sections.count == 1)  // titleless section and bare 42 dropped
        #expect(sections[0].fields.map(\.key) == ["b"])  // bogus type and defaultless number dropped
    }

    @Test func systemFieldsAcceptOnlySupportedKeys() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [{"title": "S", "fields": [
                {"type": "system", "key": "enableAssociatedMode"},
                {"type": "system", "key": "unknownFeature"}]}]}
            """)
        let all = fields(manifest)
        #expect(all.count == 1)
        guard case .system = all[0] else {
            Issue.record("expected the supported system field to survive")
            return
        }
    }

    // MARK: Picker options and defaults

    @Test func optionShorthandExpandsToTextValueAndTag() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [{"title": "S", "fields": [
                {"type": "picker", "key": "p", "label": "P", "options": ["fast", "slow"]}]}]}
            """)
        guard case .picker(let picker) = fields(manifest)[0] else {
            Issue.record("expected a picker"); return
        }
        #expect(picker.options[0].value == .string("fast"))
        #expect(picker.options[0].tag == "fast")
        #expect(picker.defaultValue == .string("fast"))  // no default → first option
    }

    /// A localized option text cannot stand in for `value`; the option
    /// throws and the tolerant section decode drops the whole picker.
    @Test func localizedOptionTextRequiresAnExplicitValue() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [{"title": "S", "fields": [
                {"type": "picker", "key": "p1", "label": "P",
                 "options": [{"text": {"en": "Fast"}}]},
                {"type": "picker", "key": "p2", "label": "P",
                 "options": [{"text": {"en": "Fast"}, "value": 1}]}]}]}
            """)
        let all = fields(manifest)
        #expect(all.map(\.key) == ["p2"])
        guard case .picker(let picker) = all[0] else { return }
        #expect(picker.options[0].value == .number(1))
        #expect(picker.options[0].tag == nil)
    }

    @Test func pickerDefaultResolvesByIndexOrTagWithFallback() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [{"title": "S", "fields": [
                {"type": "picker", "key": "a", "label": "A", "options": ["x", "y"], "default": 1},
                {"type": "picker", "key": "b", "label": "B", "options": ["x", "y"], "default": "y"},
                {"type": "picker", "key": "c", "label": "C", "options": ["x", "y"], "default": 9},
                {"type": "picker", "key": "d", "label": "D", "options": ["x", "y"], "default": "zz"}]}]}
            """)
        let values = fields(manifest).map(\.defaultJSONValue)
        #expect(values[0] == .string("y"))   // index
        #expect(values[1] == .string("y"))   // tag
        #expect(values[2] == .string("x"))   // out-of-range index → first option
        #expect(values[3] == .string("x"))   // unknown tag → first option
    }

    // MARK: Schema acceptance

    @Test func acceptsMatchesValuesAgainstTheDeclaredSchema() throws {
        let manifest = try decode("""
            {"entry": "e", "settings": [{"title": "S", "fields": [
                {"type": "toggle", "key": "t", "label": "T", "default": false},
                {"type": "textField", "key": "s", "label": "S"},
                {"type": "number", "key": "n", "label": "N", "default": 1},
                {"type": "picker", "key": "p", "label": "P", "options": ["x", "y"]},
                {"type": "multiSelect", "key": "m", "label": "M", "options": ["x", "y"]},
                {"type": "system", "key": "enableAssociatedMode"}]}]}
            """)
        let all = fields(manifest)
        let toggle = all[0], text = all[1], number = all[2]
        let picker = all[3], multi = all[4], system = all[5]

        #expect(toggle.accepts(.bool(true)) && !toggle.accepts(.number(1)))
        #expect(text.accepts(.string("v")) && !text.accepts(.bool(true)))
        #expect(number.accepts(.number(0)) && !number.accepts(.string("0")))

        #expect(picker.accepts(.string("x")))
        #expect(!picker.accepts(.string("zz")))  // out-of-set value rejected

        #expect(multi.accepts(.array([.string("x"), .string("y")])))
        #expect(multi.accepts(.array([])))
        #expect(!multi.accepts(.array([.string("zz")])))
        #expect(!multi.accepts(.string("x")))  // non-array rejected

        #expect(!system.accepts(.bool(true)))  // always intercepted upstream
    }

    // MARK: Conditions

    private func decodeCondition(_ json: String) throws -> Manifest.Condition {
        try JSONDecoder().decode(Manifest.Condition.self, from: Data(json.utf8))
    }

    @Test func leafOperatorsEvaluateAgainstStoredValues() throws {
        let equals = try decodeCondition(#"{"key": "mode", "equals": "fast"}"#)
        #expect(equals.evaluate(["mode": .string("fast")]))
        #expect(!equals.evaluate(["mode": .string("slow")]))

        let contains = try decodeCondition(#"{"key": "n", "in": [1, 2]}"#)
        #expect(contains.evaluate(["n": .number(1)]))
        #expect(!contains.evaluate(["n": .number(3)]))

        let excludes = try decodeCondition(#"{"key": "n", "notIn": [1]}"#)
        #expect(!excludes.evaluate(["n": .number(1)]))
        #expect(excludes.evaluate(["n": .number(2)]))
    }

    /// A missing key evaluates as `.null`, so negative operators become
    /// permanently satisfied — the documented typo hazard.
    @Test func missingKeysEvaluateAsNull() throws {
        #expect(try decodeCondition(#"{"key": "gone", "equals": null}"#).evaluate([:]))
        #expect(!(try decodeCondition(#"{"key": "gone", "equals": true}"#).evaluate([:])))
        #expect(try decodeCondition(#"{"key": "gone", "notEquals": true}"#).evaluate([:]))
        #expect(try decodeCondition(#"{"key": "gone", "notIn": [1, 2]}"#).evaluate([:]))
    }

    @Test func compositeConditionsNestAndShortCircuit() throws {
        let bareArray = try decodeCondition("""
            [{"key": "a", "equals": true}, {"key": "b", "equals": true}]
            """)
        #expect(bareArray.evaluate(["a": .bool(true), "b": .bool(true)]))
        #expect(!bareArray.evaluate(["a": .bool(true), "b": .bool(false)]))

        let anyOf = try decodeCondition("""
            {"anyOf": [{"key": "a", "equals": 1}, {"not": {"key": "b", "equals": 2}}]}
            """)
        #expect(anyOf.evaluate(["a": .number(0), "b": .number(3)]))   // via the not-branch
        #expect(!anyOf.evaluate(["a": .number(0), "b": .number(2)]))
    }

    @Test func leafWithoutAnOperatorFailsToDecode() {
        #expect(throws: DecodingError.self) {
            _ = try decodeCondition(#"{"key": "a"}"#)
        }
    }

    // MARK: JSONValue

    @Test func jsonValueDistinguishesBoolFromNumber() throws {
        let decoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(#"{"b": true, "n": 1, "s": "1", "z": null}"#.utf8))
        #expect(decoded["b"] == .bool(true))
        #expect(decoded["n"] == .number(1))
        #expect(decoded["s"] == .string("1"))
        #expect(decoded["z"] == JSONValue.null)
    }

    @Test func jsonValueSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = JSONValue.object([
            "list": .array([.number(1), .bool(false), .null]),
            "nested": .object(["k": .string("v")]),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == original)
    }

    // MARK: Localizable

    private func makeLocalizable(_ json: String) throws -> JavaScriptEngine.Localizable {
        try JSONDecoder().decode(JavaScriptEngine.Localizable.self, from: Data(json.utf8))
    }

    @Test func localizableFallsBackDeterministically() throws {
        #expect(try makeLocalizable(#""plain""#).resolved() == "plain")
        #expect(try makeLocalizable(#"{"zz": "Z", "en": "E"}"#).resolved(languages: ["fr"]) == "E")
        #expect(try makeLocalizable(#"{"zz": "Z", "en": "E"}"#).resolved(languages: []) == "E")
        #expect(try makeLocalizable(#"{"zz": "Z", "aa": "A"}"#).resolved(languages: ["fr"]) == "A")
    }

    @Test func localizableResolvesExactTagBeforeAliases() throws {
        let map = #"{"zh-TW": "T", "zh-Hant": "H", "en": "E"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-TW"]) == "T")
    }

    @Test func localizableExpandsChineseScriptAliases() throws {
        #expect(try makeLocalizable(#"{"zh-Hant": "H", "en": "E"}"#)
            .resolved(languages: ["zh-TW"]) == "H")
        #expect(try makeLocalizable(#"{"zh-Hans": "S", "en": "E"}"#)
            .resolved(languages: ["zh-CN"]) == "S")
        #expect(try makeLocalizable(#"{"zh-Hant": "H"}"#)
            .resolved(languages: ["zh-HK"]) == "H")
    }

    @Test func localizableAliasOrderPrefersHantOverTW() throws {
        let map = #"{"zh-TW": "T", "zh-Hant": "H"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-HK"]) == "H")
    }

    @Test func localizableStripsScriptWhenRegionFollows() throws {
        let both = #"{"zh-TW": "T", "zh-Hant": "H"}"#
        #expect(try makeLocalizable(both).resolved(languages: ["zh-Hant-TW"]) == "T")
        #expect(try makeLocalizable(#"{"zh-Hant": "H", "en": "E"}"#)
            .resolved(languages: ["zh-Hant"]) == "H")
    }

    /// The script key follows the script the tag implies, whatever the region.
    @Test func localizableFindsTheScriptKeyForAnyChineseRegion() throws {
        let map = #"{"zh-Hant": "H", "zh-Hans": "S", "en": "E"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-Hant-GB"]) == "H")
        #expect(try makeLocalizable(map).resolved(languages: ["zh-Hans-MY"]) == "S")
        #expect(try makeLocalizable(map).resolved(languages: ["zh"]) == "S")
    }

    /// Even where the bare language implies the same script, as `zh` does Hans.
    @Test func localizableKeepsABareScriptTag() throws {
        #expect(try makeLocalizable(#"{"zh-Hans": "S", "en": "E"}"#)
            .resolved(languages: ["zh-Hans"]) == "S")
    }

    /// Stripping these would hand the user the other script's text.
    @Test func localizableKeepsAScriptTheRegionContradicts() throws {
        let map = #"{"zh-Hant": "H", "zh-Hans": "S"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-Hans-HK"]) == "S")
        #expect(try makeLocalizable(map).resolved(languages: ["zh-Hant-CN"]) == "H")
    }

    @Test func localizableFallsBackToBaseLanguage() throws {
        let map = #"{"ja": "J", "en": "E"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["ja-JP"]) == "J")
    }

    @Test func localizableMatchesKeysCaseSensitively() throws {
        let map = #"{"zh-hant": "X", "en": "E"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-TW"]) == "E")
    }

    /// An earlier preference's alias probe beats a later preference's exact
    /// match: every host exhausts one preference before trying the next.
    @Test func localizableExhaustsOneLanguageBeforeTheNext() throws {
        let map = #"{"ja": "J", "zh-TW": "T"}"#
        #expect(try makeLocalizable(map).resolved(languages: ["zh-HK", "ja"]) == "T")
    }
}
