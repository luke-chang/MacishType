import Foundation
import JavaScriptCore
import Testing

/// Conformance tests for the UTF-8 `TextDecoder` / `TextEncoder` that
/// `runtime.js` adds to the JS engine's global scope. Each test loads the
/// real `runtime.js` into a bare `JSContext` (the test bundle stages no
/// engine resources, so the source is read from disk via `#filePath`) and
/// drives the classes through evaluated expressions.
struct TextCodecTests {
    private let context: JSContext

    init() throws {
        context = try Self.makeRuntimeContext()
    }

    private enum HarnessError: Error { case load(String) }

    private static func makeRuntimeContext() throws -> JSContext {
        let context = JSContext()!

        // Bridges runtime.js touches while evaluating (the navigator IIFE
        // caches languages / user agent at load; console bridges log lazily).
        let languages: @convention(block) () -> [String] = { ["en"] }
        context.setObject(languages, forKeyedSubscript: "__MacishType_getLanguages" as NSString)
        context.setObject("MacishTypeTests", forKeyedSubscript: "__MacishType_userAgent" as NSString)
        let noopLog: @convention(block) (String, String) -> Void = { _, _ in }
        context.setObject(noopLog, forKeyedSubscript: "__MacishType_log" as NSString)

        let runtimeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacishTypeTests/
            .deletingLastPathComponent()   // macos/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("runtime/runtime.js")
        let source = try String(contentsOf: runtimeURL, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: runtimeURL)
        if let exception = context.exception {
            throw HarnessError.load(String(describing: exception))
        }

        // Test helpers: byte array -> Uint8Array, string -> code point array.
        context.evaluateScript("""
            globalThis.__U = (arr) => new Uint8Array(arr);
            globalThis.__cps = (s) => Array.from(s).map((ch) => ch.codePointAt(0));
            """)
        return context
    }

    // MARK: expression helpers

    /// A JS `Uint8Array` literal expression for the given bytes.
    private func u(_ bytes: [Int]) -> String {
        "__U([\(bytes.map(String.init).joined(separator: ","))])"
    }

    private func string(_ expr: String) -> String? {
        context.evaluateScript(expr)?.toString()
    }

    private func codePoints(_ expr: String) -> [Int]? {
        guard let array = context.evaluateScript("__cps(\(expr))")?.toArray() else { return nil }
        return array.compactMap { ($0 as? NSNumber)?.intValue }
    }

    private func bytes(_ expr: String) -> [Int]? {
        guard let array = context.evaluateScript("Array.from(\(expr))")?.toArray() else { return nil }
        return array.compactMap { ($0 as? NSNumber)?.intValue }
    }

    /// Constructor name of the error `expr` throws, or `"NONE"` if it doesn't.
    private func errorName(_ expr: String) -> String? {
        context.evaluateScript(
            "(function(){try{\(expr);return 'NONE';}catch(e){return e.constructor.name;}})()"
        )?.toString()
    }

    // MARK: labels

    @Test func acceptsUTF8Labels() {
        for label in ["utf-8", "UTF8", "  utf-8  ", "unicode-1-1-utf-8",
                      "unicode11utf8", "unicode20utf8", "x-unicode20utf8"] {
            #expect(string("new TextDecoder(\(jsString(label))).encoding") == "utf-8")
        }
        #expect(string("new TextDecoder().encoding") == "utf-8")
    }

    @Test func rejectsNonUTF8Labels() {
        for label in ["big5", "utf-16", "gbk", "shift_jis", "latin1"] {
            #expect(errorName("new TextDecoder(\(jsString(label)))") == "RangeError")
        }
    }

    // MARK: basic decode

    @Test func decodesValidSequences() {
        #expect(string("new TextDecoder().decode(\(u([0x41, 0x42])))") == "AB")
        #expect(string("new TextDecoder().decode(\(u([0xE6, 0xB8, 0xAC])))") == "測")
        #expect(codePoints("new TextDecoder().decode(\(u([0xF0, 0x9F, 0x98, 0x80])))") == [0x1F600])
        #expect(string("new TextDecoder().decode()") == "")
        #expect(string("new TextDecoder().decode(\(u([])))") == "")
    }

    // MARK: input types

    @Test func acceptsBufferSources() {
        #expect(string("new TextDecoder().decode(\(u([0xE6, 0xB8, 0xAC])).buffer)") == "測")
        // A view onto a non-zero byte offset must honor the offset/length.
        #expect(string("""
            new TextDecoder().decode(\(u([0, 0, 0xE6, 0xB8, 0xAC, 0])).subarray(2, 5))
            """) == "測")
        #expect(string("""
            (function(){const b=\(u([0, 0, 0xE6, 0xB8, 0xAC, 0])).buffer;
            return new TextDecoder().decode(new DataView(b, 2, 3));})()
            """) == "測")
    }

    @Test func rejectsNonBufferInput() {
        #expect(errorName("new TextDecoder().decode(42)") == "TypeError")
        #expect(errorName("new TextDecoder().decode('x')") == "TypeError")
        #expect(errorName("new TextDecoder().decode(null)") == "TypeError")
    }

    // MARK: replacement mode (fatal: false)

    /// U+FFFD counts follow the WHATWG maximal-subpart rule.
    @Test func replacesInvalidSequences() {
        #expect(codePoints("new TextDecoder().decode(\(u([0x80])))") == [0xFFFD])
        #expect(codePoints("new TextDecoder().decode(\(u([0xE4, 0xB8])))") == [0xFFFD])
        #expect(codePoints("new TextDecoder().decode(\(u([0xC0, 0xAF])))") == [0xFFFD, 0xFFFD])
        #expect(codePoints("new TextDecoder().decode(\(u([0xF5])))") == [0xFFFD])
        #expect(codePoints("new TextDecoder().decode(\(u([0xED, 0xA0, 0x80])))") == [0xFFFD, 0xFFFD, 0xFFFD])
        // Invalid byte between valid ones does not swallow its neighbors.
        #expect(codePoints("new TextDecoder().decode(\(u([0x41, 0x80, 0x42])))") == [0x41, 0xFFFD, 0x42])
        #expect(codePoints("new TextDecoder().decode(\(u([0xE6, 0xB8, 0xAC, 0x41])))") == [0x6E2C, 0x41])
    }

    // MARK: fatal mode

    @Test func fatalThrowsOnInvalidSequences() {
        #expect(errorName("new TextDecoder('utf-8', {fatal: true}).decode(\(u([0x80])))") == "TypeError")
        #expect(errorName("new TextDecoder('utf-8', {fatal: true}).decode(\(u([0xE4, 0xB8])))") == "TypeError")
        #expect(string("new TextDecoder('utf-8', {fatal: true}).decode(\(u([0xE6, 0xB8, 0xAC])))") == "測")
    }

    // MARK: byte-order mark

    @Test func stripsLeadingBOM() {
        #expect(string("new TextDecoder().decode(\(u([0xEF, 0xBB, 0xBF, 0x41])))") == "A")
        #expect(string("new TextDecoder().decode(\(u([0xEF, 0xBB, 0xBF])))") == "")
        // ignoreBOM keeps it; a second BOM (not the first code point) stays.
        #expect(codePoints("new TextDecoder('utf-8', {ignoreBOM: true}).decode(\(u([0xEF, 0xBB, 0xBF, 0x41])))") == [0xFEFF, 0x41])
        #expect(codePoints("new TextDecoder().decode(\(u([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])))") == [0xFEFF])
    }

    // MARK: streaming

    @Test func streamsAcrossChunks() {
        // A multibyte sequence split across chunks completes on its final byte.
        #expect(string("""
            (function(){const d=new TextDecoder();
            const a=d.decode(\(u([0xE6, 0xB8])), {stream: true});
            const b=d.decode(\(u([0xAC])));
            return a + '|' + b;})()
            """) == "|測")
    }

    @Test func flushEmitsReplacementForIncompleteTail() {
        #expect(string("""
            (function(){const d=new TextDecoder();
            return d.decode(\(u([0xE6, 0xB8])), {stream: true});})()
            """) == "")
        #expect(codePoints("""
            (function(){const d=new TextDecoder();
            d.decode(\(u([0xE6, 0xB8])), {stream: true});
            return d.decode();})()
            """) == [0xFFFD])
    }

    @Test func fatalStreamThrowsOnFlush() {
        #expect(errorName("""
            (function(){const d=new TextDecoder('utf-8', {fatal: true});
            d.decode(\(u([0xE4])), {stream: true});
            d.decode();})()
            """) == "TypeError")
    }

    @Test func bomSplitAcrossChunksIsStillStripped() {
        #expect(string("""
            (function(){const d=new TextDecoder();
            const a=d.decode(\(u([0xEF, 0xBB])), {stream: true});
            const b=d.decode(\(u([0xBF, 0x41])));
            return a + b;})()
            """) == "A")
    }

    @Test func nonStreamingCallResetsState() {
        // A prior non-streaming decode's flushed tail must not leak forward.
        #expect(string("""
            (function(){const d=new TextDecoder();
            d.decode(\(u([0xE6, 0xB8])));
            return d.decode(\(u([0x41])));})()
            """) == "A")
    }

    // MARK: TextEncoder

    @Test func encodesToUTF8() {
        #expect(bytes("new TextEncoder().encode('')") == [])
        #expect(bytes("new TextEncoder().encode('A')") == [0x41])
        #expect(bytes("new TextEncoder().encode('測')") == [0xE6, 0xB8, 0xAC])
        #expect(bytes("new TextEncoder().encode('\\u{1F600}')") == [0xF0, 0x9F, 0x98, 0x80])
        // A lone surrogate serializes to U+FFFD.
        #expect(bytes("new TextEncoder().encode('\\uD800')") == [0xEF, 0xBF, 0xBD])
        #expect(string("new TextEncoder().encoding") == "utf-8")
        #expect(string("(new TextEncoder().encode('x') instanceof Uint8Array).toString()") == "true")
    }

    @Test func roundTrips() {
        let sample = "Hello 測試 🎉 world"
        #expect(string("new TextDecoder().decode(new TextEncoder().encode(\(jsString(sample))))") == sample)
    }

    // MARK: optional host fast-path hooks
    //
    // Feature-detected per call, so JS stubs can exercise the contract
    // (this bridge itself registers neither hook).

    @Test func decodeHookHandlesWholeNonStreamingDecodes() {
        context.evaluateScript("""
            globalThis.__hookCalls = [];
            globalThis.__MacishType_decodeUTF8 = (bytes, ignoreBOM) => {
                __hookCalls.push([Array.from(bytes), ignoreBOM]);
                return "HOOKED";
            };
            """)
        #expect(string("new TextDecoder().decode(\(u([0x41, 0x42])))") == "HOOKED")
        #expect(string("JSON.stringify(__hookCalls[0])") == "[[65,66],false]")
        #expect(string("new TextDecoder('utf-8', {ignoreBOM: true}).decode(\(u([0x41])))") == "HOOKED")
        #expect(string("JSON.stringify(__hookCalls[1])") == "[[65],true]")
    }

    @Test func decodeHookDeclineFallsBackToTheStateMachine() {
        // Anything but a string falls back to the pure-JS path.
        context.evaluateScript("globalThis.__MacishType_decodeUTF8 = () => null;")
        #expect(codePoints("new TextDecoder().decode(\(u([0x41, 0x80, 0x42])))") == [0x41, 0xFFFD, 0x42])
        context.evaluateScript("globalThis.__MacishType_decodeUTF8 = () => undefined;")
        #expect(string("new TextDecoder().decode(\(u([0x41])))") == "A")
    }

    @Test func decodeHookSkipsStreamChunksAndContinuations() {
        context.evaluateScript("""
            globalThis.__hookCalls = 0;
            globalThis.__MacishType_decodeUTF8 = () => { __hookCalls++; return "X"; };
            """)
        #expect(string("""
            (function(){const d=new TextDecoder();
            const a=d.decode(\(u([0xE6, 0xB8])), {stream: true});
            const b=d.decode(\(u([0xAC])));
            return __hookCalls + '|' + a + b;})()
            """) == "0|測")
        // A continuation with no pending bytes stays gated; the next whole
        // decode takes the hook again.
        #expect(string("""
            (function(){const d=new TextDecoder();
            d.decode(\(u([0xE6, 0xB8, 0xAC])), {stream: true});
            const flushed = d.decode(\(u([0x41])));
            const gated = __hookCalls;
            return gated + '|' + flushed + '|' + d.decode(\(u([0x42])));})()
            """) == "0|A|X")
    }

    @Test func decodeHookServesFatalModeDecodes() {
        // Fatal decodes flow through the hook too — hence the contract:
        // hooks decline invalid input, never substitute U+FFFD.
        context.evaluateScript("globalThis.__MacishType_decodeUTF8 = () => 'X';")
        #expect(string("new TextDecoder('utf-8', {fatal: true}).decode(\(u([0x41])))") == "X")
    }

    @Test func encodeHookProvidesTheEncoding() {
        context.evaluateScript("""
            globalThis.__encodeInputs = [];
            globalThis.__MacishType_encodeUTF8 = (str) => {
                __encodeInputs.push(str);
                return new Uint8Array([1, 2, 3]);
            };
            """)
        #expect(bytes("new TextEncoder().encode('hi')") == [1, 2, 3])
        // The hook receives the String()-coerced input.
        #expect(bytes("new TextEncoder().encode(42)") == [1, 2, 3])
        #expect(string("__encodeInputs.join('|')") == "hi|42")
    }

    /// JSON-quote a string for safe embedding in an evaluated expression.
    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())  // strip the array brackets
    }
}
