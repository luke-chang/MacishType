import Cocoa
import Combine
import JavaScriptCore
import OSLog

/// Abstract base class for `InputEngine`s implemented in JavaScript.
///
/// Subclasses must override `engineID` (system-level identity) and
/// `engineFolderURL` (URL of the engine's folder — bundle resource or
/// external location). The folder must contain a `manifest.json` at its
/// root with an `entry` field naming the JS entry module relative to the
/// folder. Each per-text-field `InputEngineContext` gets its own JS class
/// instance constructed lazily from the entry module's default export.
///
/// The default `importRoot` is the entire engine folder; subclasses
/// override `importRoot` only to narrow the import scope (e.g. limit to
/// `src/`).
///
/// Do not instantiate `JavaScriptEngine` directly — it has no `engineID`
/// of its own and will fatalError on first config read.
///
/// Uses WebKit's private JavaScriptCore module API (declared in
/// `JSCSPI.h` bridging header) to load engine code as ES modules.
class JavaScriptEngine: InputEngine, ObservableObject {

    var engineFolderURL: URL? { nil }

    /// File-system root for `import "file://..."`; module imports outside
    /// it are rejected. Defaults to the whole engine folder so subdir
    /// entries (e.g. `src/index.js`) can import siblings; subclasses
    /// override only to narrow.
    var importRoot: URL? { engineFolderURL }

    nonisolated private static let manifestFileName = "manifest.json"

    // MARK: Manifest state

    /// Last manifest parsed by `reloadManifest()`. Survives load failures
    /// (teardown leaves it in place) so settings UI can distinguish
    /// "manifest parsed OK, entry broken" from "manifest itself broken".
    /// `@Published` drives `objectWillChange` so SwiftUI views holding
    /// `@ObservedObject` on the engine re-render on every manifest swap
    /// (folder pick / clear / FSEvents stale → reload).
    @Published private(set) var manifest: Manifest?

    /// Snapshot of user-edited settings aligned with the current manifest
    /// schema. Refreshed at every `reloadManifest()` via sanitize against
    /// `manifest`. Reset to `[:]` when `manifest == nil` so the blob in
    /// UserDefaults — which is preserved across that transition — can
    /// restore values on the next successful manifest load.
    ///
    /// No Swift-side consumer yet; UI binds to `ManifestSettingsStore`
    /// straight off the UserDefaults blob.
    private(set) var settings: [String: JSONValue] = [:]

    /// Mutable mirror of `manifest?.candidateWindow`, re-seeded on every
    /// `reloadManifest()`. Engine JS code writes here via the
    /// `manifest.candidateWindow.x = y` Proxy (see runtime.js); reads
    /// return cache values (manifest declarations OR engine writes).
    /// Settings UI continues to read `engine.manifest` (immutable static
    /// declarations) for its hide-logic — engine writes are invisible
    /// to the UI by design.
    private var candidateWindowCache = Manifest.CandidateWindowOverrides()

    /// Fields that engine JS code cannot override at runtime. Read remains
    /// available (returns manifest-declared value or nil). Writes to these
    /// log a warning and are ignored — host-only fields like
    /// `animationDuration` belong to the host.
    private static let readOnlyCandidateWindowFields: Set<String> = [
        "animationDuration",
    ]

    /// nil on missing / malformed manifest (already logged).
    nonisolated private static func parseManifest(in folder: URL) -> Manifest? {
        let manifestURL = folder.appending(path: manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            Logger.javaScriptEngine.error(
                "manifest.json missing at \(manifestURL.path, privacy: .public)"
            )
            return nil
        }
        #if DEBUG
        Logger.javaScriptEngine.debug(
            "loaded manifest: \(manifestURL.path, privacy: .public)"
        )
        #endif
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            Logger.javaScriptEngine.error(
                "manifest.json malformed at \(manifestURL.path, privacy: .public)"
            )
            return nil
        }
        return manifest
    }

    /// Subclass override point for pre-read setup (e.g. sandbox scope
    /// acquire). nil return → `reloadManifest` sets `self.manifest = nil`.
    func readManifestFromDisk() -> Manifest? {
        guard let folder = engineFolderURL else { return nil }
        let result = Self.parseManifest(in: folder)
        if result != nil {
            recordLoadedFile(folder.appending(path: Self.manifestFileName))
        }
        return result
    }

    // MARK: Settings storage

    /// Reloads manifest from disk, then aligns the settings cache and blob
    /// against it.
    final func reloadManifest() {
        manifest = readManifestFromDisk()
        // Re-seed the engine-side cache from the freshly parsed manifest.
        // Engine writes via `manifest.candidateWindow.x = y` from JS only
        // mutate this cache, not the parsed manifest — so reloading is the
        // single point where cache returns to declared-values state.
        candidateWindowCache = manifest?.candidateWindow ?? .init()
        sanitizeBlobAndRefreshCache()
    }

    /// Per-activate hook: in addition to the base's UserDefaults-backed
    /// ivars, re-decode + sanitize the settings blob so a UI edit between
    /// sessions becomes visible to engine.settings (and to JS via the push
    /// inside `sanitizeBlobAndRefreshCache`).
    override func reloadConfig() {
        super.reloadConfig()
        sanitizeBlobAndRefreshCache()
    }

    private func sanitizeBlobAndRefreshCache() {
        let next: [String: JSONValue]
        if manifest == nil {
            next = [:]
        } else {
            let key = InputEngine.composedKey(
                engineID: engineID, subKey: InputEngine.manifestSettingsSubKey)
            let raw = ManifestSettingsStore.decode(forKey: key)
            let sanitized = sanitizedSettings(from: raw)
            if sanitized != raw {
                ManifestSettingsStore.encode(sanitized, forKey: key)
            }
            next = sanitized
        }
        settings = next
        pushSettingsToJS()
    }

    /// Reshape the raw blob to match the current manifest schema: drop
    /// keys not declared by any field, replace type-mismatched values with
    /// field default, fill declared-but-missing keys with field default.
    /// Each drop / replace is logged.
    private func sanitizedSettings(from raw: [String: JSONValue]) -> [String: JSONValue] {
        guard let sections = manifest?.settings else { return [:] }
        let declared = Dictionary(uniqueKeysWithValues:
            sections.flatMap { $0.fields }.map { ($0.key, $0) })

        for key in raw.keys where declared[key] == nil {
            Logger.javaScriptEngine.notice(
                "settings: dropped stale key '\(key, privacy: .public)' not in manifest"
            )
        }

        var result: [String: JSONValue] = [:]
        for (key, field) in declared {
            if let stored = raw[key], field.accepts(stored) {
                result[key] = stored
            } else {
                if raw[key] != nil {
                    Logger.javaScriptEngine.notice(
                        "settings: type mismatch for '\(key, privacy: .public)' — using default"
                    )
                }
                result[key] = field.defaultJSONValue
            }
        }
        return result
    }

    /// Pure file-existence check for picker-flow validators. Localized
    /// error text lives in the picker-owning subclass.
    nonisolated static func hasValidManifest(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: manifestFileName).path)
    }

    // MARK: Settings → JS bridge

    private static func marshal(_ value: JSONValue) -> Any {
        switch value {
        case .null:            return NSNull()
        case .bool(let b):     return b
        case .number(let n):   return n
        case .string(let s):   return s
        case .array(let arr):  return arr.map { marshal($0) }
        case .object(let obj): return obj.mapValues { marshal($0) }
        }
    }

    /// No-op when `jsContext` is nil (engine not yet loaded). In the live
    /// path, runtime.js has already registered `__MacishType_setSettings`
    /// before `jsContext` is set, so a missing global means runtime.js
    /// failed to evaluate — a bridge-structural fault.
    private func pushSettingsToJS() {
        guard let context = jsContext else { return }
        // Dedup against JS-side state, not Swift cache — reloadConfig may
        // populate `settings` while jsContext is nil, leaving a fresh
        // context's JS-side dict empty despite the Swift cache looking up
        // to date.
        guard lastPushedSettings != settings else { return }
        let dict = settings.mapValues { Self.marshal($0) }
        guard let updater = context.objectForKeyedSubscript("__MacishType_setSettings"),
              updater.isObject else {
            Logger.javaScriptEngine.fault(
                "__MacishType_setSettings missing — runtime.js not loaded?"
            )
            return
        }
        updater.call(withArguments: [dict])
        lastPushedSettings = settings
    }

    /// What the current `jsContext` has been told. Reset on teardown
    /// since a fresh JSContext starts with an empty JS-side dict.
    private var lastPushedSettings: [String: JSONValue]?

    // MARK: candidateWindow cache → JS bridge

    /// Unwraps `Optional<T>` to `Any?` without the double-wrap trap that
    /// implicit coercion produces: `return value` where `value` is `Int?`
    /// nil would land as `Any?.some(Optional<Int>.none)`, which breaks
    /// `?? NSNull()` fallback in the bridge closure.
    private static func toAny<T>(_ value: T?) -> Any? {
        if let v = value { return v }
        return nil
    }

    private func applyCandidateWindowField(_ field: String, _ jsValue: JSValue) {
        if Self.readOnlyCandidateWindowFields.contains(field) {
            Logger.javaScriptEngine.notice(
                "manifest.candidateWindow.\(field, privacy: .public) is read-only — write ignored"
            )
            return
        }
        switch field {
        case "layoutDirection":
            guard let s = jsValue.toString(),
                  let dir = CandidateWindow.LayoutDirection(rawValue: s) else {
                warnInvalidWrite(field, "must be \"horizontal\" or \"vertical\"", jsValue)
                return
            }
            candidateWindowCache.layoutDirection = dir
        case "fontSize":
            guard jsValue.isNumber,
                  let n = Int(exactly: jsValue.toDouble()), n >= 8 else {
                warnInvalidWrite(field, "must be an integer >= 8", jsValue)
                return
            }
            candidateWindowCache.fontSize = n
        case "indexLabels":
            guard let s = jsValue.toString(),
                  CandidateWindowConfiguration.isValidIndexLabels(s) else {
                warnInvalidWrite(field, "must be ASCII printable (0x20-0x7E)", jsValue)
                return
            }
            candidateWindowCache.indexLabels = s
        case "pageSize":
            guard jsValue.isNumber,
                  let n = Int(exactly: jsValue.toDouble()),
                  CandidateWindowConfiguration.isValidPageSize(n) else {
                warnInvalidWrite(
                    field,
                    "must be integer in \(CandidateWindowConfiguration.validPageSizeRange)",
                    jsValue)
                return
            }
            candidateWindowCache.pageSize = n
        case "widerExpandedColumns":
            guard jsValue.isBoolean else {
                warnInvalidWrite(field, "must be boolean", jsValue); return
            }
            candidateWindowCache.widerExpandedColumns = jsValue.toBool()
        case "moveOnExpand":
            guard jsValue.isBoolean else {
                warnInvalidWrite(field, "must be boolean", jsValue); return
            }
            candidateWindowCache.moveOnExpand = jsValue.toBool()
        case "horizontalMaxVisibleRows":
            guard jsValue.isNumber, let n = Int(exactly: jsValue.toDouble()), n >= 2 else {
                warnInvalidWrite(field, "must be an integer >= 2", jsValue); return
            }
            candidateWindowCache.horizontalMaxVisibleRows = n
        case "verticalMinVisibleRows":
            guard jsValue.isNumber, let n = Int(exactly: jsValue.toDouble()), n >= 1 else {
                warnInvalidWrite(field, "must be an integer >= 1", jsValue); return
            }
            candidateWindowCache.verticalMinVisibleRows = n
        case "expandable":
            guard jsValue.isBoolean else {
                warnInvalidWrite(field, "must be boolean", jsValue); return
            }
            candidateWindowCache.expandable = jsValue.toBool()
        default:
            // Unknown field — typo or forward-compat (engine wrote a name
            // the host doesn't recognize, possibly because the field hasn't
            // landed yet or was removed). Same warn-and-ignore policy.
            Logger.javaScriptEngine.notice(
                "manifest.candidateWindow.\(field, privacy: .public) is not a recognized field — write ignored"
            )
        }
    }

    private func warnInvalidWrite(
        _ field: String, _ reason: String, _ jsValue: JSValue
    ) {
        Logger.javaScriptEngine.notice(
            "manifest.candidateWindow.\(field, privacy: .public) write ignored — \(reason, privacy: .public); got \(jsValue.toString() ?? "(unknown)", privacy: .public)"
        )
    }

    private func readCandidateWindowField(_ field: String) -> Any? {
        let c = candidateWindowCache
        switch field {
        case "layoutDirection":          return Self.toAny(c.layoutDirection?.rawValue)
        case "fontSize":                 return Self.toAny(c.fontSize)
        case "indexLabels":              return Self.toAny(c.indexLabels)
        case "pageSize":                 return Self.toAny(c.pageSize)
        case "widerExpandedColumns":     return Self.toAny(c.widerExpandedColumns)
        case "moveOnExpand":             return Self.toAny(c.moveOnExpand)
        case "horizontalMaxVisibleRows": return Self.toAny(c.horizontalMaxVisibleRows)
        case "verticalMinVisibleRows":   return Self.toAny(c.verticalMinVisibleRows)
        case "expandable":               return Self.toAny(c.expandable)
        default: return nil
        }
    }

    private func listCandidateWindowFields() -> [String] {
        var fields: [String] = []
        let c = candidateWindowCache
        if c.layoutDirection != nil { fields.append("layoutDirection") }
        if c.fontSize != nil { fields.append("fontSize") }
        if c.indexLabels != nil { fields.append("indexLabels") }
        if c.pageSize != nil { fields.append("pageSize") }
        if c.widerExpandedColumns != nil { fields.append("widerExpandedColumns") }
        if c.moveOnExpand != nil { fields.append("moveOnExpand") }
        if c.horizontalMaxVisibleRows != nil { fields.append("horizontalMaxVisibleRows") }
        if c.verticalMinVisibleRows != nil { fields.append("verticalMinVisibleRows") }
        if c.expandable != nil { fields.append("expandable") }
        return fields
    }

    // MARK: JSContext state (set up in load())

    fileprivate var virtualMachine: JSVirtualMachine!
    private var jsContext: JSContext!
    private var engineClass: JSValue?
    // Auto-removes entries on context dealloc; pointer-personality keeps
    // lookup identity-based regardless of future Hashable conformance on
    // `InputEngineContext`.
    private let jsInstances = NSMapTable<InputEngineContext, JSValue>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: [.strongMemory]
    )

    // Source registry for the module loader: when JSC re-fetches module
    // identifiers (including the entry's own URL), look them up here.
    fileprivate var moduleSourceByIdentifier: [String: (source: String, url: URL)] = [:]

    /// Canonical absolute paths of files read off disk by the engine —
    /// manifest.json, entry script, and every dynamically-imported module.
    /// Reset at the start of `load()` and on teardown. Consumed by
    /// file-watching subclasses (e.g. `JSExternalEngine`) to scope reloads
    /// to files in the engine's import graph. Note: settings-preview
    /// `reloadManifest()` may populate the manifest entry before any
    /// `load()`; that's harmless because watchers only run post-`load`.
    private(set) var loadedFilePaths: Set<String> = []

    // JSModuleLoaderDelegate is an ObjC protocol requiring NSObjectProtocol
    // conformance; InputEngine isn't NSObject-derived. Use a small NSObject
    // shim that forwards back to weak self.
    private lazy var moduleLoader = ModuleLoader(owner: self)

    // MARK: Lifecycle

    override func load() {
        guard jsContext == nil else { return }

        loadedFilePaths.removeAll()

        Logger.javaScriptEngine.info("load() invoked for engine '\(self.engineID, privacy: .public)'")

        let vm = JSVirtualMachine()!
        let context = JSContext(virtualMachine: vm)!

        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "(no message)"
            let stack = exception?.objectForKeyedSubscript("stack")?.toString()
                ?? "(no stack)"
            Logger.javaScriptEngine.fault(
                "JS exception: \(message, privacy: .public)\nstack: \(stack, privacy: .public)"
            )
        }

        context.moduleLoaderDelegate = moduleLoader

        // Inject __MacishType_log BEFORE evaluating runtime.js — its console
        // polyfill builds wrapper closures that call this primitive.
        let logFn: @convention(block) (String, String) -> Void = { level, message in
            switch level {
            case "debug":
                Logger.javaScriptEngine.debug("\(message, privacy: .public)")
            case "info":
                Logger.javaScriptEngine.info("\(message, privacy: .public)")
            case "notice":
                Logger.javaScriptEngine.notice("\(message, privacy: .public)")
            case "error":
                Logger.javaScriptEngine.error("\(message, privacy: .public)")
            case "fault":
                Logger.javaScriptEngine.fault("\(message, privacy: .public)")
            default:
                Logger.javaScriptEngine.notice(
                    "[\(level, privacy: .public)] \(message, privacy: .public)"
                )
            }
        }
        context.setObject(logFn, forKeyedSubscript: "__MacishType_log" as NSString)

        // candidateWindow Proxy bridges — must exist before runtime.js eval
        // (which builds the Proxy referencing these) and before the first
        // reloadManifest() below (which seeds candidateWindowCache).
        let setCWField: @convention(block) (String, JSValue) -> Void = { [weak self] field, jsValue in
            self?.applyCandidateWindowField(field, jsValue)
        }
        context.setObject(setCWField, forKeyedSubscript: "__MacishType_setCandidateWindowField" as NSString)

        let getCWField: @convention(block) (String) -> Any = { [weak self] field in
            self?.readCandidateWindowField(field) ?? NSNull()
        }
        context.setObject(getCWField, forKeyedSubscript: "__MacishType_getCandidateWindowField" as NSString)

        let listCWFields: @convention(block) () -> [String] = { [weak self] in
            self?.listCandidateWindowFields() ?? []
        }
        context.setObject(listCWFields, forKeyedSubscript: "__MacishType_candidateWindowFields" as NSString)

        // Auto-evaluate runtime.js (registers console, future file I/O, etc.)
        // before any engine code runs. Must run after __MacishType_log injection.
        guard let runtime = Self.loadJSSource(
            Bundle.main.url(forResource: "runtime", withExtension: "js", subdirectory: "JavaScript"),
            label: "runtime.js"
        ) else { return }
        context.evaluateScript(runtime.source, withSourceURL: runtime.url)

        self.virtualMachine = vm
        self.jsContext = context

        // Roll back partial state on failure so retries see a clean slate.
        var success = false
        defer { if !success { teardownContext() } }

        guard let folder = self.engineFolderURL else {
            Logger.javaScriptEngine.fault(
                "no engineFolderURL for '\(self.engineID, privacy: .public)'"
            )
            return
        }
        // Unconditional re-read so manifest and entry script come from
        // the same disk snapshot (avoid stale-cache vs new-disk mismatch).
        reloadManifest()
        guard let manifest = self.manifest else { return }
        let entryURL = folder.appending(path: manifest.entry)
        guard let entry = Self.loadJSSource(
            entryURL, label: "entry script for '\(self.engineID)'"
        ) else { return }
        recordLoadedFile(entryURL)
        let entrySource = entry.source

        // Register entry source so module loader can re-resolve its sourceURL.
        // JSC re-fetches the entry via fetchModuleForIdentifier even though we
        // pass the constructed JSScript directly; the loader looks up the URL
        // here.
        moduleSourceByIdentifier[entryURL.absoluteString] = (entrySource, entryURL)

        let entryScript: JSScript
        do {
            entryScript = try JSScript(
                of: .module,
                withSource: entrySource,
                andSourceURL: entryURL,
                andBytecodeCache: nil,
                in: vm
            )
        } catch {
            Logger.javaScriptEngine.fault(
                "failed to build entry JSScript for '\(self.engineID, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return
        }

        guard let promise = context.evaluateJSScript(entryScript) else {
            Logger.javaScriptEngine.fault(
                "evaluateJSScript returned nil (exception during evaluation)"
            )
            return
        }

        // Sync-resolve: registering .then on a settled promise fires callback
        // immediately. No microtask drain needed.
        let captureBlock: @convention(block) (JSValue) -> Void = { [weak self] namespace in
            self?.engineClass = namespace.objectForKeyedSubscript("default")
            Logger.javaScriptEngine.info("module loaded, engineClass captured")
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { reason in
            Logger.javaScriptEngine.fault(
                "module evaluation rejected: \(reason.toString() ?? "?", privacy: .public)"
            )
        }
        promise.invokeMethod("then", withArguments: [captureBlock, rejectBlock])

        // Module reject (top-level throw, missing default export, etc.) leaves
        // engineClass nil; must return so defer rolls back.
        guard engineClass != nil else {
            Logger.javaScriptEngine.fault(
                "engine class not captured after module evaluation for '\(self.engineID, privacy: .public)'"
            )
            return
        }

        success = true
        super.load()
    }

    /// Subclasses inspect this after `super.load()` to detect success vs
    /// faulted state.
    var isModuleLoaded: Bool { engineClass != nil }

    override var candidateWindowConfiguration: CandidateWindowConfiguration {
        var config = super.candidateWindowConfiguration
        config.apply(candidateWindowCache)
        return config
    }

    override func unload() {
        teardownContext()
        super.unload()
    }

    private func teardownContext() {
        jsContext = nil
        virtualMachine = nil
        engineClass = nil
        jsInstances.removeAllObjects()
        moduleSourceByIdentifier.removeAll()
        loadedFilePaths.removeAll()
        moduleLoader.invalidateRootCache()
        // self.manifest intentionally NOT cleared — see its doc comment.
        lastPushedSettings = nil
    }

    override func activate(context: InputEngineContext, clientIdentifier: String?) {
        super.activate(context: context, clientIdentifier: clientIdentifier)
        guard let instance = jsInstance(for: context) else { return }
        Self.invokeIfDefined(instance, "activate", withArguments: [])
    }

    override func deactivate(context: InputEngineContext, clientIdentifier: String?) {
        // Don't construct on deactivate — only call if instance already exists.
        guard let instance = jsInstances.object(forKey: context) else { return }
        Self.invokeIfDefined(instance, "deactivate", withArguments: [])
    }

    // MARK: Event Handling

    override func handleKey(
        context: InputEngineContext,
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        guard let instance = jsInstance(for: context) else {
            return .notHandled
        }

        let sink = ActionSink()
        let event = makeEvent(
            keyCode: keyCode, characters: characters, modifiers: modifiers,
            context: context, candidateWindow: candidateWindow,
            sink: sink
        )

        let handled = Self.invokeIfDefined(instance, "handleKey", withArguments: [event])?
            .toBool() ?? false

        if !handled && sink.actions.isEmpty {
            return .notHandled
        }
        return .handled(sink.actions)
    }

    override func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, raw: Candidate?
    ) -> [EngineAction] {
        dispatchCandidate("candidateConfirmed", context: context, candidate: candidate, raw: raw)
    }

    override func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, raw: Candidate
    ) -> [EngineAction] {
        dispatchCandidate("candidateSelectionChanged", context: context, candidate: candidate, raw: raw)
    }

    private func dispatchCandidate(
        _ jsMethod: String,
        context: InputEngineContext, candidate: String, raw: Candidate?
    ) -> [EngineAction] {
        guard let instance = jsInstance(for: context) else { return [] }
        let sink = ActionSink()
        let event = makeConfirmEvent(context: context, candidate: candidate, raw: raw, sink: sink)
        Self.invokeIfDefined(instance, jsMethod, withArguments: [event])
        return sink.actions
    }

    // MARK: Helpers

    /// Calls `instance[method](...args)` only if the JS class actually defines
    /// the method. JSC's `invokeMethod` throws TypeError on undefined, but
    /// the bridge contract is duck-typed: engines may opt out of any of
    /// `activate / deactivate / handleKey / candidateConfirmed /
    /// candidateSelectionChanged`.
    @discardableResult
    private static func invokeIfDefined(
        _ instance: JSValue, _ method: String, withArguments args: [Any]
    ) -> JSValue? {
        guard let fn = instance.objectForKeyedSubscript(method), !fn.isUndefined else {
            return nil
        }
        return instance.invokeMethod(method, withArguments: args)
    }

    fileprivate func recordLoadedFile(_ url: URL) {
        loadedFilePaths.insert(Self.canonicalPath(for: url))
    }

    /// Same on-disk file → same string regardless of how callers spelled
    /// the URL. Lets FSEvents paths, recorded load paths, and the import
    /// containment check compare against each other cleanly.
    nonisolated static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Resolves a `URL?` and reads its contents as UTF-8 text. Faults +
    /// returns nil on missing URL or read failure; `label` shows up in the
    /// fault log to disambiguate the call site (e.g. "runtime.js" vs
    /// "entry script for 'JSExternal'").
    private static func loadJSSource(_ url: URL?, label: String) -> (source: String, url: URL)? {
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

    /// Reference-type wrapper so `@convention(block)` closures can mutate a
    /// shared `[EngineAction]` buffer. Obj-C blocks capture by value by
    /// default; capturing a `var [EngineAction]` directly would write to
    /// snapshot copies invisible from outside the block.
    private final class ActionSink {
        var actions: [EngineAction] = []
    }

    private func jsInstance(for context: InputEngineContext) -> JSValue? {
        if let existing = jsInstances.object(forKey: context) { return existing }
        // Nil engineClass means load() already faulted; return silently.
        guard let engineClass else { return nil }
        guard let instance = engineClass.construct(withArguments: []) else {
            Logger.javaScriptEngine.fault(
                "engineClass.construct returned nil for '\(self.engineID, privacy: .public)'"
            )
            return nil
        }
        jsInstances.setObject(instance, forKey: context)
        return instance
    }

    private func makeEvent(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        context: InputEngineContext,
        candidateWindow: CandidateWindowState,
        sink: ActionSink
    ) -> JSValue {
        let pure = modifiers.intersection(.deviceIndependentFlagsMask)
        let modifiersDict: [String: Bool] = [
            "shift": pure.contains(.shift),
            "ctrl": pure.contains(.control),
            "option": pure.contains(.option),
            "command": pure.contains(.command),
        ]

        let event = JSValue(newObjectIn: jsContext)!
        event.setObject(keyCode, forKeyedSubscript: "keyCode" as NSString)
        if let characters {
            event.setObject(characters, forKeyedSubscript: "characters" as NSString)
        } else {
            event.setObject(NSNull(), forKeyedSubscript: "characters" as NSString)
        }
        event.setObject(modifiersDict, forKeyedSubscript: "modifiers" as NSString)
        event.setObject(context.markedText, forKeyedSubscript: "markedText" as NSString)
        event.setObject(context.stagedText, forKeyedSubscript: "stagedText" as NSString)
        event.setObject(context.isComposing, forKeyedSubscript: "isComposing" as NSString)
        event.setObject(context.isAssociating, forKeyedSubscript: "isAssociating" as NSString)

        let cw = JSValue(newObjectIn: jsContext)!
        cw.setObject(candidateWindow.isVisible,
                     forKeyedSubscript: "isVisible" as NSString)
        cw.setObject(candidateWindow.configuration.indexLabels,
                     forKeyedSubscript: "indexLabels" as NSString)
        cw.setObject(candidateWindow.configuration.pageSize,
                     forKeyedSubscript: "pageSize" as NSString)
        cw.setObject(candidateWindow.configuration.layoutDirection.rawValue,
                     forKeyedSubscript: "layoutDirection" as NSString)
        let candidateIndex: @convention(block) (String) -> Any = { char in
            guard let firstChar = char.first,
                  let index = candidateWindow.configuration.candidateIndex(for: firstChar) else {
                return NSNull()
            }
            return index
        }
        cw.setObject(candidateIndex, forKeyedSubscript: "candidateIndex" as NSString)
        event.setObject(cw, forKeyedSubscript: "candidateWindow" as NSString)

        attachMutators(to: event, sink: sink)
        return event
    }

    private func makeConfirmEvent(
        context: InputEngineContext,
        candidate: String,
        raw: Candidate?,
        sink: ActionSink
    ) -> JSValue {
        let event = JSValue(newObjectIn: jsContext)!
        event.setObject(candidate, forKeyedSubscript: "candidate" as NSString)
        if let annotation = raw?.annotation {
            event.setObject(annotation, forKeyedSubscript: "annotation" as NSString)
        }
        if let payload = raw?.payload {
            event.setObject(payload, forKeyedSubscript: "payload" as NSString)
        }
        event.setObject(context.markedText, forKeyedSubscript: "markedText" as NSString)
        event.setObject(context.stagedText, forKeyedSubscript: "stagedText" as NSString)
        event.setObject(context.isComposing, forKeyedSubscript: "isComposing" as NSString)
        event.setObject(context.isAssociating, forKeyedSubscript: "isAssociating" as NSString)
        attachMutators(to: event, sink: sink)
        return event
    }

    // JSC's @convention(block) bridge stringifies JS undefined to "undefined"
    // for String? params (instead of nil). Always take optional JS args as
    // JSValue? and unwrap via this helper, which filters nil / isUndefined /
    // isNull together.
    private static func resolved(_ value: JSValue?) -> JSValue? {
        guard let v = value, !v.isUndefined, !v.isNull else { return nil }
        return v
    }

    /// Reads an Int from `obj[key]`. Returns nil for missing / non-number
    /// values (vs `toInt32()` which silently coerces to 0).
    private static func optInt(_ obj: JSValue?, _ key: String) -> Int? {
        guard let v = resolved(obj?.objectForKeyedSubscript(key)), v.isNumber else { return nil }
        return Int(v.toInt32())
    }

    /// Builds a `configure` closure for `EngineAction.updateCandidates` from
    /// flat JS options. Returns nil when no override fields are present so
    /// the engine default applies.
    private static func parseCandidateWindowOverrides(
        _ opts: JSValue?
    ) -> ((inout CandidateWindowConfiguration) -> Void)? {
        guard let opts else { return nil }
        let layoutString = Self.resolved(opts.objectForKeyedSubscript("layoutDirection"))?.toString()
        let layoutDirection = layoutString.flatMap(CandidateWindow.LayoutDirection.init(rawValue:))
        let indexLabels = Self.resolved(opts.objectForKeyedSubscript("indexLabels"))?.toString()
        let pageSize = Self.optInt(opts, "pageSize")

        if layoutDirection == nil && indexLabels == nil && pageSize == nil {
            return nil
        }
        return { config in
            if let layoutDirection { config.layoutDirection = layoutDirection }
            if let indexLabels { config.indexLabels = indexLabels }
            if let pageSize { config.pageSize = pageSize }
        }
    }

    /// Builds a `Candidate` from either a JS string or `{candidate, annotation?, payload?}` object.
    /// Falls back to `value.toString()` when the object lacks `candidate`.
    private static func candidateFromJS(_ value: JSValue) -> Candidate {
        // Plain-string candidates skip the 3 property lookups — common path
        // when engines emit `[String]` or call `event.commit("text")`.
        if value.isString { return Candidate(value.toString() ?? "") }
        if let textVal = Self.resolved(value.objectForKeyedSubscript("candidate")) {
            let annotation = Self.resolved(value.objectForKeyedSubscript("annotation"))?.toString()
            let payload = Self.resolved(value.objectForKeyedSubscript("payload"))
            return Candidate(textVal.toString() ?? "", annotation: annotation, payload: payload)
        }
        return Candidate(value.toString() ?? "")
    }

    /// Inverse of `candidateFromJS(_:)`. Wraps a `Candidate` into a
    /// JS-friendly dict so engines round-trip the annotation/payload they
    /// emitted in `updateCandidates`.
    private static func jsFromCandidate(_ candidate: Candidate?) -> Any {
        candidate.map { c -> [String: Any] in
            var dict: [String: Any] = ["candidate": c.text]
            if let annotation = c.annotation { dict["annotation"] = annotation }
            if let payload = c.payload { dict["payload"] = payload }
            return dict
        } ?? NSNull()
    }

    private func attachMutators(to event: JSValue, sink: ActionSink) {
        // cursor: nil vs 0 are distinct (nil = default-to-text-count, 0 =
        // caret at start). emphasis is a half-open character-index range
        // (NOT UTF-16). See EngineAction.updateMarkedText for staged semantics.
        let updateMarkedText: @convention(block) (String, JSValue?) -> Void = { text, options in
            let opts = Self.resolved(options)
            let cursor = Self.optInt(opts, "cursor")
            let staged = Self.optInt(opts, "staged") ?? 0
            var emphasis: Range<Int>?
            if let e = Self.resolved(opts?.objectForKeyedSubscript("emphasis")),
               let lo = Self.optInt(e, "start"), let hi = Self.optInt(e, "end"), lo <= hi {
                emphasis = lo..<hi
            }
            sink.actions.append(
                .updateMarkedText(text, cursor: cursor, emphasis: emphasis, staged: staged)
            )
        }
        let resetContext: @convention(block) () -> Void = {
            sink.actions.append(.resetContext)
        }
        // items accepts [String] (backward-compatible) or [{text, annotation?,
        // payload?}] objects — "text" key picks the object branch, otherwise
        // toString fallback. First param is JSValue (whole array) not [JSValue]:
        // JSC's ObjC bridge gives NSArray<NSString> for JS string arrays and
        // Swift traps casting NSTaggedPointerString to JSValue.
        // options may include layoutDirection / indexLabels / pageSize to
        // override engine default config for this single update (mirrors
        // Swift's `configure` closure on the action).
        let updateCandidates: @convention(block) (JSValue, JSValue?) -> Void = { itemsArr, options in
            let opts = Self.resolved(options)
            let offset = opts?.objectForKeyedSubscript("offset")?.toInt32() ?? 0
            let suspendHighlight = opts?
                .objectForKeyedSubscript("suspendHighlight")?.toBool() ?? false
            let count = Int(itemsArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            let candidates = (0..<count).compactMap { i -> Candidate? in
                guard let item = itemsArr.objectAtIndexedSubscript(i) else { return nil }
                return Self.candidateFromJS(item)
            }
            sink.actions.append(.updateCandidates(
                candidates,
                offset: Int(offset),
                suspendHighlight: suspendHighlight,
                configure: Self.parseCandidateWindowOverrides(opts)))
        }
        // Accepts either a plain string or `{text, annotation?, payload?}` —
        // engines reusing a Candidate received in candidateConfirmed can pass
        // it back to preserve metadata.
        let commit: @convention(block) (JSValue) -> Void = { value in
            sink.actions.append(.commit(Self.candidateFromJS(value)))
        }
        let commitSelectedCandidate: @convention(block) () -> Void = {
            sink.actions.append(.commitSelectedCandidate)
        }
        let commitCandidateAtIndex: @convention(block) (Int) -> Void = { index in
            sink.actions.append(.commitCandidateAtIndex(index))
        }
        let navigateCandidates: @convention(block) (String, JSValue?) -> Void = { dirStr, options in
            let dir = Self.parseNavigationDirection(dirStr)
            let wrapping = Self.resolved(options)?
                .objectForKeyedSubscript("wrapping")?.toBool() ?? false
            sink.actions.append(.navigateCandidates(dir, wrapping: wrapping))
        }
        let flushStaged: @convention(block) (JSValue?) -> Void = { append in
            let text = Self.resolved(append)?.toString() ?? ""
            sink.actions.append(.flushStaged(text))
        }
        let enterAssociatedMode: @convention(block) (String, [String]) -> Void = { heldChar, candidates in
            sink.actions.append(.enterAssociatedMode(heldChar, candidates))
        }

        event.setObject(updateMarkedText, forKeyedSubscript: "updateMarkedText" as NSString)
        event.setObject(resetContext, forKeyedSubscript: "resetContext" as NSString)
        event.setObject(updateCandidates, forKeyedSubscript: "updateCandidates" as NSString)
        event.setObject(commit, forKeyedSubscript: "commit" as NSString)
        event.setObject(commitSelectedCandidate, forKeyedSubscript: "commitSelectedCandidate" as NSString)
        event.setObject(commitCandidateAtIndex, forKeyedSubscript: "commitCandidateAtIndex" as NSString)
        event.setObject(navigateCandidates, forKeyedSubscript: "navigateCandidates" as NSString)
        event.setObject(flushStaged, forKeyedSubscript: "flushStaged" as NSString)
        event.setObject(enterAssociatedMode, forKeyedSubscript: "enterAssociatedMode" as NSString)
    }

    private static func parseNavigationDirection(_ str: String) -> NavigationDirection {
        switch str {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        case "pageForward": return .pageForward
        case "pageBackward": return .pageBackward
        case "itemForward": return .itemForward
        case "itemBackward": return .itemBackward
        default:
            Logger.javaScriptEngine.error(
                "unknown navigation direction: \(str, privacy: .public), defaulting to .down")
            return .down
        }
    }
}

// MARK: - Module loader shim

/// NSObject shim that conforms to the `JSModuleLoaderDelegate` ObjC protocol
/// and forwards to its owning `JavaScriptEngine`. The engine itself can't
/// conform directly because the protocol requires `NSObjectProtocol` and
/// `InputEngine` (the base class) isn't NSObject-derived.
private final class ModuleLoader: NSObject, JSModuleLoaderDelegate {
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

    /// Verifies `target`'s canonical path is at or below the cached root,
    /// matching with a trailing `/` so `/foo` doesn't match `/foobar`.
    private func isContained(url target: URL, rootPath: String) -> Bool {
        let normalizedTarget = JavaScriptEngine.canonicalPath(for: target)
        if normalizedTarget == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return normalizedTarget.hasPrefix(prefix)
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

        // Engine-local relative imports (file:// outside our cache).
        if id.hasPrefix("file://"), let url = URL(string: id) {
            // Defense-in-depth on top of the sandbox: containment check rejects
            // `../foo`-style escapes and symlinks that point out of the engine
            // folder before the read syscall runs.
            guard let rootPath = normalizedRootPath() else {
                Logger.javaScriptEngine.error(
                    "file import disabled: no importRoot for '\(owner.engineID, privacy: .public)'"
                )
                reject.call(withArguments: ["file imports disabled"])
                return
            }
            guard isContained(url: url, rootPath: rootPath) else {
                Logger.javaScriptEngine.error(
                    "import \(id, privacy: .public) outside engine folder \(rootPath, privacy: .public)"
                )
                reject.call(withArguments: ["import outside engine folder: \(id)"])
                return
            }
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                owner.recordLoadedFile(url)
                #if DEBUG
                Logger.javaScriptEngine.debug(
                    "loaded module: \(url.path, privacy: .public)"
                )
                #endif
                let script = try JSScript(
                    of: .module,
                    withSource: source,
                    andSourceURL: url,
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

// MARK: - Manifest overrides apply

extension CandidateWindowConfiguration {
    /// Apply non-nil fields from `overrides` onto self. All fields were
    /// already type- and value-validated at decode time (see
    /// `Manifest.CandidateWindowOverrides.init`); this is pure assignment
    /// on the hot path (called per `.updateCandidates`).
    mutating func apply(_ overrides: JavaScriptEngine.Manifest.CandidateWindowOverrides) {
        if let v = overrides.layoutDirection { layoutDirection = v }
        if let v = overrides.fontSize { fontSize = CGFloat(v) }
        if let v = overrides.indexLabels { indexLabels = v }
        if let v = overrides.pageSize { pageSize = v }
        if let v = overrides.widerExpandedColumns { widerExpandedColumns = v }
        if let v = overrides.moveOnExpand { moveOnExpand = v }
        if let v = overrides.horizontalMaxVisibleRows { horizontalMaxVisibleRows = v }
        if let v = overrides.verticalMinVisibleRows { verticalMinVisibleRows = v }
        if let v = overrides.expandable { expandable = v }
    }
}

