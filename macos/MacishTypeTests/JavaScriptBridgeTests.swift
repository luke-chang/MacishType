import JavaScriptCore
import Testing

/// The bridge's element-level text rule, matching `Qjs::optionalText` on the
/// other hosts.
@MainActor
struct JavaScriptBridgeTests {
    private func evaluate(_ script: String) -> JSValue? {
        JSContext()?.evaluateScript(script)
    }

    /// Positions are part of the result: dropping an odd element would shift
    /// the indices `candidateConfirmed` reports back.
    @Test func textArrayStringifiesEveryElement() {
        #expect(JavaScriptEngine.textArray(evaluate("[undefined, null, '甲', 42, {}]"))
            == ["", "", "甲", "42", "[object Object]"])
    }

    /// An object is a candidate even without `candidate`; anything else takes
    /// the text rule.
    @Test func candidateFromJSReadsOddItemsByTheTextRule() {
        let items = evaluate("[undefined, null, 42, {annotation: 'x'}, {candidate: '甲'}, '乙']")!
        let candidates = (0..<6).map {
            JavaScriptEngine.candidateFromJS(items.objectAtIndexedSubscript($0))
        }
        #expect(candidates.map(\.text) == ["", "", "42", "", "甲", "乙"])
        #expect(candidates[3].annotation == "x")
    }

    /// The payload is opaque, so a null round-trips while a missing one stays
    /// absent.
    @Test func candidateFromJSKeepsANullPayload() {
        let items = evaluate("[{candidate: '甲', payload: null}, {candidate: '乙'}]")!
        let withNull = JavaScriptEngine.candidateFromJS(items.objectAtIndexedSubscript(0))
        #expect((withNull.payload as? JSValue)?.isNull == true)
        #expect(JavaScriptEngine.candidateFromJS(items.objectAtIndexedSubscript(1)).payload == nil)
    }

    /// Unlike candidates, codes hold no index in place, so the empty ones drop.
    @Test func reverseCodesStringifyAndDropEmptyOnes() {
        let codes = JavaScriptEngine.marshalReverseCodes(evaluate(
            "['', 5001, null, {code: 7, annotation: 8}, {code: ''}, {annotation: 'x'}]")!)
        #expect(codes.map(\.code) == ["5001", "7"])
        #expect(codes.map(\.annotation) == [nil, "8"])
        #expect(JavaScriptEngine.marshalReverseCodes(evaluate("['']")!).isEmpty)
    }

    @Test func intValueSaturatesInsteadOfWrapping() {
        #expect(JavaScriptEngine.intValue(evaluate("NaN")) == nil)
        #expect(JavaScriptEngine.intValue(evaluate("'2'")) == nil)
        #expect(JavaScriptEngine.intValue(evaluate("undefined")) == nil)
        #expect(JavaScriptEngine.intValue(evaluate("2.7")) == 2)
        #expect(JavaScriptEngine.intValue(evaluate("-2.7")) == -2)
        #expect(JavaScriptEngine.intValue(evaluate("2 ** 32")) == Int(Int32.max))
        #expect(JavaScriptEngine.intValue(evaluate("Infinity")) == Int(Int32.max))
        #expect(JavaScriptEngine.intValue(evaluate("-Infinity")) == Int(Int32.min))
    }

    /// `CandidateWindowConfiguration` traps on labels or page sizes it can't
    /// hold, so the per-update overrides drop them along with mistyped values.
    @Test func windowOverridesDropValuesTheConfigurationRejects() {
        #expect(JavaScriptEngine.parseCandidateWindowOverrides(
            evaluate("({indexLabels: '中', pageSize: 99, layoutDirection: 42})")) == nil)
        #expect(JavaScriptEngine.parseCandidateWindowOverrides(
            evaluate("({indexLabels: 42})")) == nil)
        // A fraction is rejected rather than truncated, and 2 ** 32 + 3 is out
        // of range rather than a valid 3.
        #expect(JavaScriptEngine.parseCandidateWindowOverrides(
            evaluate("({pageSize: 2.5})")) == nil)
        #expect(JavaScriptEngine.parseCandidateWindowOverrides(
            evaluate("({pageSize: 2 ** 32 + 3})")) == nil)

        var configuration = CandidateWindowConfiguration()
        JavaScriptEngine.parseCandidateWindowOverrides(
            evaluate("({indexLabels: 'asdf', pageSize: 4})"))?(&configuration)
        #expect(configuration.indexLabels == "asdf")
        #expect(configuration.pageSize == 4)
    }

    /// The array here is sparse, so this measures the cap alone.
    @Test func textArrayCapsAnOversizedLength() {
        #expect(JavaScriptEngine.textArray(evaluate("new Array(3e9)"))?.count
            == Int(JavaScriptEngine.maxListItems))
    }

    /// Only "no list given" lets a caller fall back to its own source.
    @Test func textArrayDeclinesAnythingButAnArray() {
        #expect(JavaScriptEngine.textArray(evaluate("undefined")) == nil)
        #expect(JavaScriptEngine.textArray(evaluate("null")) == nil)
        #expect(JavaScriptEngine.textArray(evaluate("'甲'")) == nil)
        #expect(JavaScriptEngine.textArray(nil) == nil)
        #expect(JavaScriptEngine.textArray(evaluate("[]")) == [])
    }
}
