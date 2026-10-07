import JavaScriptCore
import Testing

private typealias JSONValue = JavaScriptEngine.JSONValue

@MainActor
struct JSONHandoffTests {
    private let context = JSContext()!

    private func evaluate(_ dictionary: [String: some Encodable], _ script: String) -> String? {
        context.setObject(JavaScriptEngine.jsObject(dictionary, sortingKeys: true, in: context),
                          forKeyedSubscript: "value" as NSString)
        return context.evaluateScript(script)?.toString()
    }

    @Test func protoKeysStayOwnProperties() {
        let settings: [String: JSONValue] = [
            "__proto__": .object(["leaked": .bool(true)]),
            "nested": .object(["__proto__": .number(1)]),
        ]
        #expect(evaluate(settings, "Object.keys(value).sort().join()") == "__proto__,nested")
        #expect(evaluate(settings, """
            Object.getPrototypeOf(value) === Object.prototype && value.leaked === undefined
              && Object.getPrototypeOf(value.nested) === Object.prototype
              && Object.hasOwn(value.nested, '__proto__')
            """) == "true")
    }

    @Test func keysArriveSorted() {
        let settings: [String: JSONValue] = [
            "b": .number(1), "c": .number(2), "a": .object(["z": .null, "y": .null]),
        ]
        #expect(evaluate(settings, "Object.keys(value).join() + '|' + Object.keys(value.a).join()")
            == "a,b,c|y,z")
    }

    /// Settings are pushed again after engine code has run.
    @Test func ignoresAnEngineReplacingJSONParse() {
        context.evaluateScript("JSON.parse = () => ({})")
        #expect(evaluate(["key": "value"], "value.key") == "value")
    }
}
