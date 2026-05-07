class JSExternalEngine: JavaScriptEngine {
    static let shared = JSExternalEngine()

    override class var engineID: String { "JSExternal" }

    override class var entryScriptURL: URL? {
        Bundle.main.url(forResource: "JSExternal", withExtension: "js", subdirectory: "JSExternal")
    }
}
