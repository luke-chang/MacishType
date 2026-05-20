import Foundation
import JavaScriptCore

// MARK: - engine:// URL synthesis

extension JavaScriptEngine {

    /// Shared base for all `engine:///<path>` URLs. Parsed once at type
    /// init rather than per call to `syntheticURL`.
    nonisolated static let syntheticURLBase = URL(string: "engine:///")!

    /// Build a synthetic `engine:///<path>` URL for a path relative to
    /// `engineFolderURL`. Used as sourceURL for module scripts and as
    /// `Response.url`, so JS-visible URLs never leak the user's
    /// filesystem path. `appending(path:)` handles percent-encoding for
    /// CJK / spaces / reserved chars (avoiding URL(string:) trap).
    nonisolated static func syntheticURL(forRelativePath relativePath: String) -> URL {
        syntheticURLBase.appending(path: relativePath)
    }

    /// Translate a synthetic `engine:///<path>` URL back to the real
    /// `file://` URL for disk I/O. Rejects non-engine schemes, non-empty
    /// hosts (no `engine://malicious/path` smuggling), and missing folder.
    func realFileURL(forSyntheticURL url: URL) -> URL? {
        guard url.scheme == "engine",
              (url.host ?? "").isEmpty,
              let folder = engineFolderURL else { return nil }
        // url.path for engine:///foo is "/foo"; strip the leading slash so
        // appendingPathComponent doesn't produce a double slash.
        let relative = String(url.path.dropFirst())
        return folder.appendingPathComponent(relative)
    }
}

// MARK: - fetch bridge

extension JavaScriptEngine {

    /// Reference-type box so closures can mutate a shared flag.
    /// Used for body-consumed tracking (fetch Response).
    private final class FetchBodyState {
        var consumed = false
    }

    private func engineFolderRootPath() -> String? {
        if let cached = cachedEngineFolderRoot { return cached }
        guard let folder = engineFolderURL else { return nil }
        let resolved = Self.canonicalPath(for: folder)
        cachedEngineFolderRoot = resolved
        return resolved
    }

    func handleFetch(path: String, resolve: JSValue, reject: JSValue) {
        guard let folder = engineFolderURL, let rootPath = engineFolderRootPath() else {
            Self.rejectWith(reject, message: "fetch: engine folder unavailable")
            return
        }

        // Sync path validation. `syntheticInput` captures the parsed URL on
        // the engine:/// branch, so the stat callback can build displayURL
        // without re-parsing or force-unwrapping.
        let target: URL
        let syntheticInput: URL?
        if path.hasPrefix("./") {
            syntheticInput = nil
            target = folder.appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("engine:///"), let url = URL(string: path) {
            if url.query != nil || url.fragment != nil {
                Self.rejectWith(
                    reject,
                    message: "fetch: query and fragment not supported in '\(path)'")
                return
            }
            guard let realURL = realFileURL(forSyntheticURL: url) else {
                Self.rejectWith(reject, message: "fetch: bad engine URL '\(path)'")
                return
            }
            syntheticInput = url
            target = realURL
        } else {
            Self.rejectWith(
                reject,
                message: "fetch: path must start with './' or 'engine:///' (got '\(path)')")
            return
        }
        guard Self.isContained(url: target, in: rootPath) else {
            Self.rejectWith(reject, message: "fetch: path '\(path)' escapes engine folder")
            return
        }

        // Stat on background — engine folder may sit on network volume /
        // sleeping disk / iCloud stub; can't block the main thread.
        // resolve/reject retain their JSContext, so they're callable even if
        // engine teardown happens before the read completes.
        Self.statFile(url: target) { [weak self] result in
            switch result {
            case .success(let type):
                guard type == .regular else {
                    Self.rejectWith(reject, message: "fetch: '\(path)' is not a regular file")
                    return
                }
                self?.recordLoadedFile(target)
                let displayURL = syntheticInput
                    ?? Self.syntheticURL(forRelativePath: String(path.dropFirst(2)))
                guard let ctx = resolve.context else { return }
                resolve.call(withArguments: [
                    Self.makeFetchResponse(in: ctx, realURL: target, displayURL: displayURL)
                ])
            case .failure(let error):
                Self.rejectWith(
                    reject,
                    message: "fetch: not reachable '\(path)': \(error.localizedDescription)")
            }
        }
    }

    /// Response with lazy body — actual disk read happens inside body
    /// method closures, not at fetch() time. `realURL` is the file URL
    /// used for I/O; `displayURL` is the synthetic engine:/// URL exposed
    /// to JS via `Response.url` (keeps the user's filesystem path private).
    /// Body-consumed flag uses lock-on-entry semantics (sync mark before
    /// dispatch) with unmark on recoverable failure for fallback / retry.
    private static func makeFetchResponse(in ctx: JSContext, realURL: URL, displayURL: URL) -> JSValue {
        let response = JSValue(newObjectIn: ctx)!
        response.setObject(true, forKeyedSubscript: "ok" as NSString)
        response.setObject(200, forKeyedSubscript: "status" as NSString)
        response.setObject(displayURL.absoluteString, forKeyedSubscript: "url" as NSString)

        let state = FetchBodyState()

        let textFn: @convention(block) () -> JSValue = {
            Self.textBody(state: state, url: realURL) { text, resolve, _ in
                resolve.call(withArguments: [text])
            }
        }
        response.setObject(textFn, forKeyedSubscript: "text" as NSString)

        let jsonFn: @convention(block) () -> JSValue = {
            Self.textBody(state: state, url: realURL) { text, resolve, _ in
                // Promise.resolve(text).then(JSON.parse) — outer adopts inner
                // so SyntaxError surfaces as rejection, web-aligned.
                guard let ctx = resolve.context else { return }
                let jsonParse = ctx.objectForKeyedSubscript("JSON")!
                    .objectForKeyedSubscript("parse")!
                let resolved = Self.resolvedPromise(in: ctx, value: text)
                let parsed = resolved.invokeMethod("then", withArguments: [jsonParse])!
                resolve.call(withArguments: [parsed])
            }
        }
        response.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

        let arrayBufferFn: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            if state.consumed {
                return Self.rejectedPromise(in: ctx, message: "Body has already been consumed")
            }
            state.consumed = true
            return Self.deferredPromise(in: ctx) { resolve, reject in
                Self.readRaw(url: realURL) { result in
                    switch result {
                    case .success(let data):
                        guard let ctx = resolve.context else { return }
                        guard let buffer = Self.makeArrayBuffer(from: data, in: ctx) else {
                            state.consumed = false
                            Self.rejectWith(reject, message: "Failed to construct ArrayBuffer")
                            return
                        }
                        resolve.call(withArguments: [buffer])
                    case .failure(let error):
                        state.consumed = false
                        Self.rejectWith(
                            reject,
                            message: "Body read failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        response.setObject(arrayBufferFn, forKeyedSubscript: "arrayBuffer" as NSString)

        return response
    }

    private static func resolvedPromise(in ctx: JSContext, value: Any) -> JSValue {
        ctx.objectForKeyedSubscript("Promise")!
            .invokeMethod("resolve", withArguments: [value])
    }

    private static func rejectedPromise(in ctx: JSContext, message: String) -> JSValue {
        let promiseClass = ctx.objectForKeyedSubscript("Promise")!
        let errorClass = ctx.objectForKeyedSubscript("Error")!
        let error = errorClass.construct(withArguments: [message])!
        return promiseClass.invokeMethod("reject", withArguments: [error])
    }

    /// Build an Error and invoke a Promise-style reject callback.
    /// Used both by handleFetch sync rejects and body-method async rejects.
    private static func rejectWith(_ reject: JSValue, message: String) {
        guard let ctx = reject.context else { return }
        let errorClass = ctx.objectForKeyedSubscript("Error")!
        let error = errorClass.construct(withArguments: [message])!
        reject.call(withArguments: [error])
    }

    /// Builds an ArrayBuffer-typed JSValue. Goes through the JSC C API
    /// because the ObjC JSValue bridge doesn't expose an ArrayBuffer
    /// initializer. Copies bytes into a heap buffer that JSC frees via
    /// the deallocator when the ArrayBuffer is GC'd. Returns nil on
    /// allocation failure so callers can surface a rejection rather than
    /// resolving with `undefined`.
    private static func makeArrayBuffer(from data: Data, in ctx: JSContext) -> JSValue? {
        // `allocate(byteCount: 0, ...)` is unspecified; route empty files
        // through JS-side construction to avoid UB.
        if data.isEmpty {
            return ctx.evaluateScript("new ArrayBuffer(0)")
        }
        let count = data.count
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        data.copyBytes(to: ptr.assumingMemoryBound(to: UInt8.self), count: count)
        let deallocator: JSTypedArrayBytesDeallocator = { bytes, _ in
            bytes?.deallocate()
        }
        var exception: JSValueRef?
        guard let bufferRef = JSObjectMakeArrayBufferWithBytesNoCopy(
            ctx.jsGlobalContextRef,
            ptr, count,
            deallocator, nil,
            &exception
        ) else {
            ptr.deallocate()
            return nil
        }
        return JSValue(jsValueRef: bufferRef, in: ctx)
    }

    /// Sentinel for UTF-8 decode failure inside `readAndDecode`.
    /// Caller distinguishes via `error is InvalidUTF8` to choose between
    /// "not valid UTF-8" message and generic read-failure message.
    private struct InvalidUTF8: Error {}

    /// Shared shape for `text()` and `json()` body methods: lock-on-entry,
    /// dispatch UTF-8 decode, unmark + classify error on failure, hand the
    /// decoded text to the caller for per-method post-processing on success.
    private static func textBody(
        state: FetchBodyState,
        url: URL,
        onText: @escaping (String, JSValue, JSValue) -> Void
    ) -> JSValue {
        let ctx = JSContext.current()!
        if state.consumed {
            return Self.rejectedPromise(in: ctx, message: "Body has already been consumed")
        }
        state.consumed = true
        return Self.deferredPromise(in: ctx) { resolve, reject in
            Self.readAndDecode(url: url) { result in
                switch result {
                case .success(let text):
                    onText(text, resolve, reject)
                case .failure(let error):
                    state.consumed = false
                    let message = error is InvalidUTF8
                        ? "Body is not valid UTF-8"
                        : "Body read failed: \(error.localizedDescription)"
                    Self.rejectWith(reject, message: message)
                }
            }
        }
    }

    /// Stat on background queue using URL.resourceValues, which follows
    /// symlinks (symlink-to-regular returns .regular, matching what
    /// `Data(contentsOf:)` will see at read time).
    private static func statFile(
        url: URL,
        completion: @escaping (Result<URLFileResourceType, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URLFileResourceType, Error>
            do {
                let values = try url.resourceValues(forKeys: [.fileResourceTypeKey])
                result = .success(values.fileResourceType ?? .unknown)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Read + UTF-8 decode on background, deliver Result on main.
    /// UTF-8 failure surfaces as `.failure(InvalidUTF8())`; disk read
    /// failure surfaces as `.failure(realError)`.
    private static func readAndDecode(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do {
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8) {
                    result = .success(text)
                } else {
                    result = .failure(InvalidUTF8())
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Read raw bytes on background, deliver Result on main.
    private static func readRaw(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Data(contentsOf: url) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Construct `new Promise((resolve, reject) => work(resolve, reject))`
    /// from Swift. Used by body methods to defer Promise settlement until
    /// background read completes.
    private static func deferredPromise(
        in ctx: JSContext,
        _ work: @escaping (JSValue, JSValue) -> Void
    ) -> JSValue {
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            work(resolve, reject)
        }
        return ctx.objectForKeyedSubscript("Promise")!.construct(withArguments: [executor])!
    }
}
