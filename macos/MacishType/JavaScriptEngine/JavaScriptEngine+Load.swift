import Foundation
import JavaScriptCore
import OSLog

// MARK: - Exception describing

extension JavaScriptEngine {

    /// `JSValue.toString()` on an undefined value returns the literal string
    /// "undefined" — treat it as absent alongside nil / isUndefined / isNull.
    static func stringIfDefined(_ value: JSValue?) -> String? {
        guard let v = resolved(value),
              let s = v.toString(), !s.isEmpty, s != "undefined" else { return nil }
        return s
    }

    /// JSC populates sourceURL/line/column even when `stack` is undefined
    /// (common for engine-internal throws), so the location line is the most
    /// reliable anchor for navigating back to the source.
    static func describeJSException(_ exception: JSValue?) -> String {
        guard let exception else { return "(nil)" }
        let prop: (String) -> String? = { stringIfDefined(exception.objectForKeyedSubscript($0)) }

        let name = prop("name") ?? "Error"
        let message = prop("message") ?? exception.toString() ?? "(no message)"

        var location = ""
        if let src = prop("sourceURL") { location = src }
        if let line = prop("line") {
            location += location.isEmpty ? "line \(line)" : ":\(line)"
            if let col = prop("column") { location += ":\(col)" }
        }

        var lines = ["\(name): \(message)"]
        if !location.isEmpty { lines.append("  at \(location)") }
        if let stack = prop("stack") { lines.append("stack:\n\(stack)") }
        return lines.joined(separator: "\n")
    }

    /// Resolves a `URL?` and reads its contents as UTF-8 text. Faults +
    /// returns nil on missing URL or read failure; `label` shows up in the
    /// fault log to disambiguate the call site (e.g. "runtime.js" vs
    /// "entry script for 'JSExternal'").
    static func loadJSSource(_ url: URL?, label: String) -> (source: String, url: URL)? {
        guard let url else {
            Logger.javaScriptEngine.fault("\(label, privacy: .public): URL not provided")
            return nil
        }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            #if DEBUG
            Logger.javaScriptEngine.debug(
                "loaded \(label, privacy: .public): \(url.path, privacy: .public)"
            )
            #endif
            return (source, url)
        } catch {
            Logger.javaScriptEngine.fault(
                "\(label, privacy: .public): failed to read — \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Module loader shim

/// NSObject shim that conforms to the `JSModuleLoaderDelegate` ObjC protocol
/// and forwards to its owning `JavaScriptEngine`. The engine itself can't
/// conform directly because the protocol requires `NSObjectProtocol` and
/// `InputEngine` (the base class) isn't NSObject-derived.
final class ModuleLoader: NSObject, JSModuleLoaderDelegate {
    private weak var owner: JavaScriptEngine?
    /// Cached canonical root path. `resolvingSymlinksInPath` is a `realpath`
    /// syscall; the root doesn't change across imports in one load, so resolve
    /// once and reuse. Invalidated by `invalidateRootCache()` on teardown.
    private var cachedRootPath: String?

    init(owner: JavaScriptEngine) {
        self.owner = owner
    }

    func invalidateRootCache() {
        cachedRootPath = nil
    }

    private func normalizedRootPath() -> String? {
        if let cached = cachedRootPath { return cached }
        guard let owner, let root = owner.importRoot else { return nil }
        let resolved = JavaScriptEngine.canonicalPath(for: root)
        cachedRootPath = resolved
        return resolved
    }

    func context(
        _ context: JSContext!,
        fetchModuleForIdentifier identifier: JSValue!,
        withResolveHandler resolve: JSValue!,
        andRejectHandler reject: JSValue!
    ) {
        guard let owner else {
            reject.call(withArguments: ["JavaScriptEngine deallocated"])
            return
        }
        let id = identifier.toString() ?? ""
        Logger.javaScriptEngine.debug(
            "module loader: fetch \(id, privacy: .public)"
        )

        // Re-fetch of an already-known module (entry script's own sourceURL).
        if let cached = owner.moduleSourceByIdentifier[id] {
            do {
                let script = try JSScript(
                    of: .module,
                    withSource: cached.source,
                    andSourceURL: cached.url,
                    andBytecodeCache: nil,
                    in: owner.virtualMachine
                )
                resolve.call(withArguments: [script])
            } catch {
                Logger.javaScriptEngine.fault(
                    "failed to rebuild cached JSScript for \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                reject.call(withArguments: ["script construction failed: \(error)"])
            }
            return
        }

        // Engine-local relative imports — JSC resolves `./X` / `/X` against
        // the importing module's synthetic engine:/// sourceURL, so it
        // hands us engine:/// identifiers. Translate to real file URL for
        // I/O; sourceURL of the resulting JSScript stays synthetic so
        // `import.meta.url` doesn't leak the user's filesystem path.
        // Strict 3-slash prefix matches handleFetch — `engine://host/path`
        // forms fall through to "unknown module" reject, consistent with
        // realFileURL's empty-host requirement.
        if id.hasPrefix("engine:///"), let syntheticURL = URL(string: id) {
            guard let realURL = owner.realFileURL(forSyntheticURL: syntheticURL) else {
                Logger.javaScriptEngine.error(
                    "bad engine URL: \(id, privacy: .public)"
                )
                reject.call(withArguments: ["bad engine URL: \(id)"])
                return
            }
            // Defense-in-depth on top of the sandbox: containment check in
            // real-path space rejects symlinks that point out of the
            // engine folder before the read syscall runs.
            guard let rootPath = normalizedRootPath() else {
                Logger.javaScriptEngine.error(
                    "file import disabled: no importRoot for '\(owner.engineID, privacy: .public)'"
                )
                reject.call(withArguments: ["file imports disabled"])
                return
            }
            guard JavaScriptEngine.isContained(url: realURL, in: rootPath) else {
                Logger.javaScriptEngine.error(
                    "import \(id, privacy: .public) outside engine folder \(rootPath, privacy: .public)"
                )
                reject.call(withArguments: ["import outside engine folder: \(id)"])
                return
            }
            do {
                let source = try String(contentsOf: realURL, encoding: .utf8)
                owner.recordLoadedFile(realURL)
                #if DEBUG
                Logger.javaScriptEngine.debug(
                    "loaded module: \(id, privacy: .public)"
                )
                #endif
                let script = try JSScript(
                    of: .module,
                    withSource: source,
                    andSourceURL: syntheticURL,
                    andBytecodeCache: nil,
                    in: owner.virtualMachine
                )
                resolve.call(withArguments: [script])
            } catch {
                Logger.javaScriptEngine.error(
                    "failed to load file module \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                reject.call(withArguments: ["file module load failed: \(error)"])
            }
            return
        }

        Logger.javaScriptEngine.error(
            "module loader: unknown module \(id, privacy: .public)"
        )
        reject.call(withArguments: ["unknown module: \(id)"])
    }
}
