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

    /// File-system root for engine-local `import` resolution (which JS
    /// sees as `engine:///<path>` URLs); module imports resolving outside
    /// it are rejected. Defaults to the whole engine folder so subdir
    /// entries (e.g. `src/index.js`) can import siblings; subclasses
    /// override only to narrow.
    var importRoot: URL? { engineFolderURL }

    /// Root directory for this engine's `localStorage`. nil signals
    /// "no writable location" to bridges, which surface as logged
    /// no-ops rather than writing to a fallback the user can't find.
    var storageURL: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(bundleID)
            .appendingPathComponent(engineID)
    }

    /// Computed per call so folder swap (JSExternal) picks up the new
    /// location immediately.
    private var storage: JavaScriptStorage? {
        guard let url = storageURL else { return nil }
        return JavaScriptStorage(rootURL: url)
    }

    /// True when a subclass-provided FSEvent watcher already covers
    /// `storageURL`. Bundle-resource engines have no folder watcher
    /// of their own, so they need a lazy dedicated stream — see
    /// `updateStorageWatcher`. `JSExternalEngine` overrides to true.
    var hasExternalStorageWatcher: Bool { false }

    /// Canonical paths of storage files our own setItem/removeItem/
    /// clear just wrote, mapped to write time. FSEvent callback
    /// within `selfWriteWindow` of a timestamp is treated as a
    /// self-write and not redispatched. Touched only on main.
    private var recentSelfWrites: [String: Date] = [:]
    private static let selfWriteWindow: TimeInterval = 2.0

    private func recordSelfWrite(_ url: URL, at time: Date = Date()) {
        recentSelfWrites[Self.canonicalPath(for: url)] = time
    }

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

    // MARK: - System fields

    /// Backs `lookupAssociatedCandidates(for:)` and the single-arg
    /// `enterAssociatedMode` fallback while the manifest opts in.
    private var associatedDictionaryHandle: AssociatedDictionary.Handle?

    /// Maps a system feature identifier to the InputEngine subKey storing
    /// its value. When adding a new feature: also update
    /// `JSExternalEngine.clearStoredSettings` to clear on folder swap.
    private static func systemFeatureSubKey(_ feature: String) -> String? {
        switch feature {
        case "enableAssociatedMode": return InputEngine.enableAssociatedModeSubKey
        default: return nil
        }
    }

    /// First-time default for each `"type": "system"` field with a
    /// `"default"` declared. Only writes when the standalone key has no
    /// stored value — subsequent calls (after the user toggled) are no-ops.
    private func applySystemFieldDefaults(_ manifest: Manifest) {
        guard let sections = manifest.settings else { return }
        for case .system(let sf) in sections.flatMap(\.fields) {
            guard let defaultValue = sf.defaultValue,
                  let subKey = Self.systemFeatureSubKey(sf.key) else { continue }
            let storageKey = InputEngine.composedKey(engineID: engineID, subKey: subKey)
            if UserDefaults.standard.object(forKey: storageKey) == nil {
                UserDefaults.standard.set(defaultValue, forKey: storageKey)
            }
        }
    }

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
        // Apply defaults before sanitize so the standalone keys are populated
        // for the first read.
        if let m = manifest { applySystemFieldDefaults(m) }
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
            // System fields read from the standalone key (populated by
            // applySystemFieldDefaults before sanitize). The `?? false` tail
            // only fires if there's no manifest default and no user choice.
            if case .system(let sf) = field {
                if let subKey = Self.systemFeatureSubKey(sf.key) {
                    let storageKey = InputEngine.composedKey(engineID: engineID, subKey: subKey)
                    let current = (UserDefaults.standard.object(forKey: storageKey) as? Bool)
                        ?? sf.defaultValue ?? false
                    result[key] = .bool(current)
                }
                continue
            }
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

    // MARK: localStorage bridge

    private static func throwJSError(_ message: String) {
        guard let ctx = JSContext.current() else { return }
        ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
    }

    private static func logStorageUnavailable(_ op: String) {
        Logger.javaScriptEngine.error(
            "localStorage \(op, privacy: .public) failed: storage location unavailable"
        )
    }

    // MARK: Storage event pipeline

    /// `newValue` is NOT read here — JS reads it lazily only if a
    /// listener accesses `event.newValue`. Files lacking the
    /// `localStorage_` prefix (atomic-write temp files, foreign
    /// files) are skipped via decodeFilename returning nil.
    func handleStorageEvent(path: String) {
        let canonical = Self.canonicalPath(for: URL(fileURLWithPath: path))
        if let last = recentSelfWrites[canonical],
           Date().timeIntervalSince(last) < Self.selfWriteWindow {
            return
        }
        recentSelfWrites[canonical] = nil  // lazy GC stale entry
        let filename = (path as NSString).lastPathComponent
        guard let key = JavaScriptStorage.decodeFilename(filename) else {
            return
        }
        dispatchStorageEvent(key: key)
    }

    private func dispatchStorageEvent(key: String) {
        guard let context = jsContext,
              let fn = context.objectForKeyedSubscript("__MacishType_dispatchStorageEvent"),
              fn.isObject else { return }
        fn.call(withArguments: [key])
    }

    // MARK: Bundle storage watcher (lazy, listener-driven)

    private var bundleStorageWatcher: FSEventStreamRef?

    /// Toggled by JS `__MacishType_setStorageListening` when the
    /// listener count crosses 0↔1. No-op for engines with their own
    /// folder watcher (JSExternal piggybacks on the engine-folder
    /// stream); for bundle engines this is the lifecycle hook.
    private func updateStorageWatcher(active: Bool) {
        if hasExternalStorageWatcher { return }
        if active {
            if bundleStorageWatcher == nil { startBundleStorageWatcher() }
        } else {
            stopBundleStorageWatcher()
        }
    }

    private func startBundleStorageWatcher() {
        guard let url = storageURL else { return }
        // FSEventStream needs the directory to exist or it watches
        // ancestor changes we don't care about.
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let engine = Unmanaged<JavaScriptEngine>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                for path in paths { engine.handleStorageEvent(path: path) }
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            Logger.javaScriptEngine.error(
                "bundle storage FSEvents stream creation failed for \(url.path, privacy: .public)"
            )
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        bundleStorageWatcher = stream
    }

    private func stopBundleStorageWatcher() {
        guard let stream = bundleStorageWatcher else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        bundleStorageWatcher = nil
    }

    // MARK: Locale + user agent (shared across all engine instances)

    private static var sharedLocaleObserver: NSObjectProtocol?
    private static let languageSubscribers = NSHashTable<JavaScriptEngine>.weakObjects()

    /// First subscriber installs the observer; later subscribers
    /// piggyback. Per-engine `dispatchLanguageChange` reaches each
    /// live JSContext.
    private static func subscribeToLanguageChanges(_ engine: JavaScriptEngine) {
        languageSubscribers.add(engine)
        if sharedLocaleObserver != nil { return }
        sharedLocaleObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            for engine in languageSubscribers.allObjects {
                engine.dispatchLanguageChange()
            }
        }
    }

    /// Idempotent — safe to call when subscribe never ran (e.g. load
    /// defer-rollback path). NSHashTable.remove is no-op for absent
    /// entries; the observer-teardown branch checks emptiness first.
    private static func unsubscribeFromLanguageChanges(_ engine: JavaScriptEngine) {
        languageSubscribers.remove(engine)
        if languageSubscribers.count == 0, let token = sharedLocaleObserver {
            NotificationCenter.default.removeObserver(token)
            sharedLocaleObserver = nil
        }
    }

    /// Web-style BCP 47: drops script subtag when redundant.
    /// `zh-Hant-TW` → `zh-TW` (3-segment),
    /// `zh-Hant` → `zh` (2-segment with script),
    /// `en-US` → `en-US` (no script, unchanged).
    /// Matches what Safari's `navigator.languages` returns so engine
    /// code from a browser context doesn't need to handle both forms.
    nonisolated private static func normalizeBCP47(_ tag: String) -> String {
        let parts = tag.split(separator: "-").map(String.init)
        let isScript: (String) -> Bool = {
            $0.count == 4 && $0.first?.isUppercase == true
        }
        if parts.count == 3, isScript(parts[1]) {
            return "\(parts[0])-\(parts[2])"
        }
        if parts.count == 2, isScript(parts[1]) {
            return parts[0]
        }
        return tag
    }

    /// macOS Settings UI tacks the user's region onto secondary
    /// preferred languages — e.g. user picks 繁中(TW) + English while
    /// region is Taiwan, stored list becomes `[zh-Hant-TW, en-TW]`.
    /// `en-TW` is rarely meaningful; strip the region when it matches
    /// the user's region AND it's not the primary entry (which the
    /// user explicitly chose).
    nonisolated private static func stripAutoTaggedRegions(_ tags: [String]) -> [String] {
        guard let userRegion = Locale.current.region?.identifier else { return tags }
        return tags.enumerated().map { (i, tag) in
            if i == 0 { return tag }
            let parts = tag.split(separator: "-").map(String.init)
            guard parts.count >= 2, let last = parts.last else { return tag }
            let isRegion = (last.count == 2 && last.allSatisfy { $0.isUppercase })
                        || (last.count == 3 && last.allSatisfy { $0.isNumber })
            guard isRegion, last == userRegion else { return tag }
            return parts.dropLast().joined(separator: "-")
        }
    }

    /// Chrome-style expansion: each tag is followed by its base
    /// (language-only) form, deduped. Engines doing first-match get
    /// a natural fallback chain. `[zh-TW, en]` → `[zh-TW, zh, en]`.
    nonisolated private static func expandWithBases(_ tags: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for tag in tags {
            if seen.insert(tag).inserted { result.append(tag) }
            let base = String(tag.split(separator: "-").first ?? "")
            if !base.isEmpty, seen.insert(base).inserted { result.append(base) }
        }
        return result
    }

    nonisolated private static func preferredLanguagesForJS() -> [String] {
        let normalized = Locale.preferredLanguages.map(normalizeBCP47)
        let stripped = stripAutoTaggedRegions(normalized)
        return expandWithBases(stripped)
    }

    private func dispatchLanguageChange() {
        guard let context = jsContext,
              let fn = context.objectForKeyedSubscript("__MacishType_dispatchLanguageChange"),
              fn.isObject else { return }
        fn.call(withArguments: [])
    }

    /// Cached canonical path of `engineFolderURL`. Same realpath-syscall
    /// avoidance as `ModuleLoader.cachedRootPath` but keyed off the full
    /// folder (which fetch uses) rather than `importRoot` (potentially
    /// narrower). Invalidated alongside other JS state in `teardownContext`.
    var cachedEngineFolderRoot: String?

    // MARK: JSContext state (set up in load())

    var virtualMachine: JSVirtualMachine!
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
    var moduleSourceByIdentifier: [String: (source: String, url: URL)] = [:]

    /// Canonical absolute paths of files the engine has expressed interest
    /// in — manifest.json, entry script, every dynamically-imported module,
    /// and every successfully-stat'd fetched resource. Reset at the start
    /// of `load()` and on teardown. Consumed by file-watching subclasses
    /// (e.g. `JSExternalEngine`) to scope reloads.
    ///
    /// Import paths are recorded post-read-success (an import failing
    /// reading faults the whole load, leaving no half-watched file).
    /// Fetched paths are recorded post-stat-success, before the body is
    /// (or isn't) consumed — fetch alone is enough to express "I care
    /// about this file" and should drive hot-reload on later edits.
    /// Note: settings-preview `reloadManifest()` may populate the
    /// manifest entry before any `load()`; that's harmless because
    /// watchers only run post-`load`.
    private(set) var loadedFilePaths: Set<String> = []

    // JSModuleLoaderDelegate is an ObjC protocol requiring NSObjectProtocol
    // conformance; InputEngine isn't NSObject-derived. Use a small NSObject
    // shim that forwards back to weak self.
    private lazy var moduleLoader = ModuleLoader(owner: self)

    // MARK: Lifecycle

    /// Reference-type box for detecting whether the entry module's
    /// Promise settled synchronously inside invokeMethod.
    private final class SyncSettleFlag {
        var settled = false
    }

    override func load() {
        guard jsContext == nil else { return }

        Logger.javaScriptEngine.info("load() invoked for engine '\(self.engineID, privacy: .public)'")

        let vm = JSVirtualMachine()!
        let context = JSContext(virtualMachine: vm)!

        context.exceptionHandler = { _, exception in
            Logger.javaScript.fault(
                "uncaught exception:\n\(Self.describeJSException(exception), privacy: .public)"
            )
        }

        context.moduleLoaderDelegate = moduleLoader

        // Inject __MacishType_log BEFORE evaluating runtime.js — its console
        // polyfill builds wrapper closures that call this primitive.
        let logFn: @convention(block) (String, String) -> Void = { level, message in
            switch level {
            case "debug":
                Logger.javaScript.debug("\(message, privacy: .public)")
            case "info":
                Logger.javaScript.info("\(message, privacy: .public)")
            case "notice":
                Logger.javaScript.notice("\(message, privacy: .public)")
            case "error":
                Logger.javaScript.error("\(message, privacy: .public)")
            case "fault":
                Logger.javaScript.fault("\(message, privacy: .public)")
            default:
                Logger.javaScript.notice(
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

        // localStorage bridges — must register before runtime.js eval.
        let storageGetItem: @convention(block) (String) -> Any = { [weak self] key in
            guard let storage = self?.storage else {
                Self.logStorageUnavailable("getItem")
                return NSNull()
            }
            do {
                return try storage.getItem(key) ?? NSNull()
            } catch {
                Self.throwJSError(error.localizedDescription)
                return NSNull()
            }
        }
        context.setObject(storageGetItem, forKeyedSubscript: "__MacishType_storageGetItem" as NSString)

        let storageSetItem: @convention(block) (String, String) -> Void = { [weak self] key, value in
            guard let self, let storage = self.storage else {
                Self.logStorageUnavailable("setItem")
                return
            }
            do {
                if let url = try storage.setItem(key, value) {
                    self.recordSelfWrite(url)
                }
            } catch {
                Self.throwJSError(error.localizedDescription)
            }
        }
        context.setObject(storageSetItem, forKeyedSubscript: "__MacishType_storageSetItem" as NSString)

        let storageRemoveItem: @convention(block) (String) -> Void = { [weak self] key in
            guard let self, let storage = self.storage else {
                Self.logStorageUnavailable("removeItem")
                return
            }
            do {
                if let url = try storage.removeItem(key) {
                    self.recordSelfWrite(url)
                }
            } catch {
                Self.throwJSError(error.localizedDescription)
            }
        }
        context.setObject(storageRemoveItem, forKeyedSubscript: "__MacishType_storageRemoveItem" as NSString)

        let storageClear: @convention(block) () -> Void = { [weak self] in
            guard let self, let storage = self.storage else {
                Self.logStorageUnavailable("clear")
                return
            }
            let now = Date()
            for url in storage.clear() {
                self.recordSelfWrite(url, at: now)
            }
        }
        context.setObject(storageClear, forKeyedSubscript: "__MacishType_storageClear" as NSString)

        let storageKeys: @convention(block) () -> [String] = { [weak self] in
            guard let storage = self?.storage else {
                Self.logStorageUnavailable("keys")
                return []
            }
            return storage.keys()
        }
        context.setObject(storageKeys, forKeyedSubscript: "__MacishType_storageKeys" as NSString)

        let setStorageListening: @convention(block) (Bool) -> Void = { [weak self] active in
            self?.updateStorageWatcher(active: active)
        }
        context.setObject(setStorageListening, forKeyedSubscript: "__MacishType_setStorageListening" as NSString)

        // navigator bridges. Pipeline lives in preferredLanguagesForJS.
        let getLanguages: @convention(block) () -> [String] = {
            Self.preferredLanguagesForJS()
        }
        context.setObject(getLanguages, forKeyedSubscript: "__MacishType_getLanguages" as NSString)

        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                          as? String) ?? "0.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        // `Bundle(for:)` returns the framework bundle of a given class —
        // here, JavaScriptCore.framework's Info.plist.
        let jscVersion = (Bundle(for: JSContext.self)
                          .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let userAgent = "MacishType/\(appVersion) (macOS \(osVersionString)) JavaScriptCore/\(jscVersion)"
        context.setObject(userAgent, forKeyedSubscript: "__MacishType_userAgent" as NSString)

        let fetchFn: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] path, resolve, reject in
            self?.handleFetch(path: path, resolve: resolve, reject: reject)
        }
        context.setObject(fetchFn, forKeyedSubscript: "__MacishType_fetch" as NSString)

        // Auto-evaluate runtime.js before any engine code runs;
        // must follow bridge registration above.
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
        let entryRealURL = folder.appending(path: manifest.entry)
        guard let entry = Self.loadJSSource(
            entryRealURL, label: "entry script for '\(self.engineID)'"
        ) else { return }
        recordLoadedFile(entryRealURL)
        let entrySource = entry.source

        // Synthetic engine:/// URL is what JS sees as `import.meta.url` and
        // what relative imports resolve against. Disk I/O still uses the
        // real file URL (entryRealURL) — translation happens in ModuleLoader.
        let entrySyntheticURL = Self.syntheticURL(forRelativePath: manifest.entry)

        // Register entry source so module loader can re-resolve its sourceURL.
        // JSC re-fetches the entry via fetchModuleForIdentifier even though we
        // pass the constructed JSScript directly; the loader looks up the URL
        // here keyed by synthetic URL.
        moduleSourceByIdentifier[entrySyntheticURL.absoluteString] = (entrySource, entrySyntheticURL)

        let entryScript: JSScript
        do {
            entryScript = try JSScript(
                of: .module,
                withSource: entrySource,
                andSourceURL: entrySyntheticURL,
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

        // JSC drains microtasks inside invokeMethod, so a sync module's
        // callback fires before the call returns. Unsettled = top-level
        // await with real async I/O — unsupported.
        let settle = SyncSettleFlag()
        let captureBlock: @convention(block) (JSValue) -> Void = { [weak self] namespace in
            settle.settled = true
            self?.engineClass = namespace.objectForKeyedSubscript("default")
            Logger.javaScriptEngine.info("module loaded, engineClass captured")
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { reason in
            settle.settled = true
            Logger.javaScript.fault(
                "module evaluation rejected:\n\(Self.describeJSException(reason), privacy: .public)"
            )
        }
        promise.invokeMethod("then", withArguments: [captureBlock, rejectBlock])

        guard settle.settled else {
            Logger.javaScriptEngine.fault(
                "entry module of '\(self.engineID, privacy: .public)' did not settle synchronously — top-level `await` is not supported; use `.then(...)` chains instead"
            )
            return
        }
        guard engineClass != nil else { return }

        success = true
        Self.subscribeToLanguageChanges(self)
        super.load()
        // After super.load() so a mid-load early return above doesn't acquire
        // a handle for an engine that isn't actually live.
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
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
        // Drop the handle before teardown, mirroring load's acquire order.
        associatedDictionaryHandle = nil
        teardownContext()
        super.unload()
    }

    private func teardownContext() {
        // Stop watcher and clear self-write tracking before nil'ing
        // context so any in-flight FSEvent callbacks find a clean
        // state on the main runloop.
        stopBundleStorageWatcher()
        Self.unsubscribeFromLanguageChanges(self)
        recentSelfWrites.removeAll()
        jsContext = nil
        virtualMachine = nil
        engineClass = nil
        jsInstances.removeAllObjects()
        moduleSourceByIdentifier.removeAll()
        loadedFilePaths.removeAll()
        moduleLoader.invalidateRootCache()
        cachedEngineFolderRoot = nil
        // self.manifest intentionally NOT cleared — see its doc comment.
        lastPushedSettings = nil
    }

    override func activate(context: InputEngineContext, clientIdentifier: String?) {
        super.activate(context: context, clientIdentifier: clientIdentifier)
        // Catches toggle changes from between sessions — load() runs only once.
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
        guard let instance = jsInstance(for: context) else { return }
        Self.invokeIfDefined(instance, "activate", withArguments: [])
    }

    override func deactivate(context: InputEngineContext, clientIdentifier: String?) {
        // Don't construct on deactivate — only call if instance already exists.
        guard let instance = jsInstances.object(forKey: context) else { return }
        Self.invokeIfDefined(instance, "deactivate", withArguments: [])
    }

    override func lookupAssociatedCandidates(for char: Character) -> [String] {
        associatedDictionaryHandle?.lookup(char) ?? []
    }

    // MARK: Event Handling

    override func handleKey(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        guard let instance = jsInstance(for: context) else {
            return .notHandled()
        }

        let sink = ActionSink()
        let event = makeEvent(
            keyEvent: keyEvent,
            context: context, candidateWindow: candidateWindow,
            sink: sink
        )

        let handled = Self.invokeIfDefined(instance, "handleKey", withArguments: [event])?
            .toBool() ?? false

        return handled ? .handled(sink.actions) : .notHandled(sink.actions)
    }

    override func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate?,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        let (handled, actions) = dispatchCandidate(
            "candidateConfirmed", context: context, candidate: candidate,
            absoluteIndex: absoluteIndex, raw: raw, candidateWindow: candidateWindow)
        if handled { return actions }
        return actions + super.candidateConfirmed(
            context: context, candidate, absoluteIndex: absoluteIndex,
            raw: raw, candidateWindow: candidateWindow)
    }

    override func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        let (handled, actions) = dispatchCandidate(
            "candidateSelectionChanged", context: context, candidate: candidate,
            absoluteIndex: absoluteIndex, raw: raw, candidateWindow: candidateWindow)
        if handled { return actions }
        return actions + super.candidateSelectionChanged(
            context: context, candidate, absoluteIndex: absoluteIndex,
            raw: raw, candidateWindow: candidateWindow)
    }

    /// Invokes the named JS callback. `handled` reflects the JS return value
    /// alone (`true` → handled, anything else → fall back). `actions` are the
    /// mutators queued during the call, applied regardless — when falling back,
    /// callers concatenate them before the `super` result.
    private func dispatchCandidate(
        _ jsMethod: String,
        context: InputEngineContext, candidate: String, absoluteIndex: Int, raw: Candidate?,
        candidateWindow: CandidateWindowState
    ) -> (handled: Bool, actions: [EngineAction]) {
        guard let instance = jsInstance(for: context) else { return (false, []) }
        let sink = ActionSink()
        let event = makeConfirmEvent(
            context: context, candidate: candidate, absoluteIndex: absoluteIndex,
            raw: raw, candidateWindow: candidateWindow, sink: sink)
        let handled = Self.invokeIfDefined(instance, jsMethod, withArguments: [event])?
            .toBool() ?? false
        return (handled, sink.actions)
    }

    // MARK: Helpers

    /// Calls `instance[method](...args)` only if the JS class actually defines
    /// the method. JSC's `invokeMethod` throws TypeError on undefined, but
    /// the bridge contract is duck-typed: engines may opt out of any of
    /// `activate / deactivate / handleKey / candidateConfirmed /
    /// candidateSelectionChanged`.
    ///
    /// JSC's context `exceptionHandler` only fires for top-level evaluation
    /// (`evaluateScript` etc.); a throw inside `invokeMethod` is recorded on
    /// `context.exception` but does NOT trigger the handler. Check and log
    /// explicitly so engine bugs aren't silently swallowed.
    @discardableResult
    private static func invokeIfDefined(
        _ instance: JSValue, _ method: String, withArguments args: [Any]
    ) -> JSValue? {
        guard let fn = instance.objectForKeyedSubscript(method), !fn.isUndefined else {
            return nil
        }
        let result = instance.invokeMethod(method, withArguments: args)
        if let context = instance.context, let exception = context.exception {
            Logger.javaScript.fault(
                "uncaught exception in \(method, privacy: .public):\n\(Self.describeJSException(exception), privacy: .public)"
            )
            // Clear so the next invocation isn't blamed for this throw.
            context.exception = nil
        }
        return result
    }

    func recordLoadedFile(_ url: URL) {
        loadedFilePaths.insert(Self.canonicalPath(for: url))
    }

    /// Same on-disk file → same string regardless of how callers spelled
    /// the URL. Lets FSEvents paths, recorded load paths, and the import
    /// containment check compare against each other cleanly.
    nonisolated static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Trailing-slash prefix match so `/foo` doesn't accept `/foobar`,
    /// plus exact-match for the root itself.
    nonisolated static func isContained(url target: URL, in rootPath: String) -> Bool {
        let normalizedTarget = canonicalPath(for: target)
        if normalizedTarget == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return normalizedTarget.hasPrefix(prefix)
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
        keyEvent: KeyEventInput,
        context: InputEngineContext,
        candidateWindow: CandidateWindowState,
        sink: ActionSink
    ) -> JSValue {
        let pure = keyEvent.modifiers.intersection(.deviceIndependentFlagsMask)

        let event = JSValue(newObjectIn: jsContext)!
        let key = KeyboardEventMapping.webKey(for: keyEvent.keyCode, characters: keyEvent.characters)
        event.setObject(key, forKeyedSubscript: "key" as NSString)
        event.setObject(KeyboardEventMapping.webCode(for: keyEvent.keyCode),
                        forKeyedSubscript: "code" as NSString)
        event.setObject(keyEvent.charactersIgnoringModifiers ?? key,
                        forKeyedSubscript: "keyIgnoringModifiers" as NSString)
        event.setObject(pure.contains(.shift), forKeyedSubscript: "shiftKey" as NSString)
        event.setObject(pure.contains(.control), forKeyedSubscript: "ctrlKey" as NSString)
        event.setObject(pure.contains(.option), forKeyedSubscript: "altKey" as NSString)
        event.setObject(pure.contains(.command), forKeyedSubscript: "metaKey" as NSString)
        event.setObject(keyEvent.isRepeat, forKeyedSubscript: "repeat" as NSString)
        event.setObject(KeyboardEventMapping.location(for: keyEvent.keyCode),
                        forKeyedSubscript: "location" as NSString)

        // Web standard `getModifierState(key)`. Returns true only for the five
        // states macOS can faithfully report; everything else (NumLock /
        // ScrollLock / AltGraph / Hyper / Super / Symbol / etc.) returns false.
        // "Fn" is intentionally not supported — NSEvent.ModifierFlags.function
        // gets set automatically on arrow / F-keys / Page Up/Down / Home / End
        // even when no Fn key is held, which would mislead callers.
        let modifiers = keyEvent.modifiers
        let getModifierState: @convention(block) (String) -> Bool = { stateKey in
            switch stateKey {
            case "Shift": return modifiers.contains(.shift)
            case "Control": return modifiers.contains(.control)
            case "Alt": return modifiers.contains(.option)
            case "Meta": return modifiers.contains(.command)
            case "CapsLock": return modifiers.contains(.capsLock)
            default: return false
            }
        }
        event.setObject(getModifierState, forKeyedSubscript: "getModifierState" as NSString)

        attachEventContext(to: event, context: context, candidateWindow: candidateWindow)
        attachMutators(to: event, sink: sink)
        return event
    }

    /// Mirrors the shape of TS `EventContext`: the fields every event payload
    /// (KeyEvent, ConfirmEvent) shares. Adding a new context field is now a
    /// one-line edit here instead of touching every makeXxxEvent helper.
    private func attachEventContext(
        to event: JSValue, context: InputEngineContext, candidateWindow: CandidateWindowState
    ) {
        event.setObject(context.markedText, forKeyedSubscript: "markedText" as NSString)
        event.setObject(context.stagedText, forKeyedSubscript: "stagedText" as NSString)
        event.setObject(context.isComposing, forKeyedSubscript: "isComposing" as NSString)
        event.setObject(context.isAssociating, forKeyedSubscript: "isAssociating" as NSString)
        attachCandidateWindow(to: event, candidateWindow: candidateWindow)
    }

    private func attachCandidateWindow(
        to event: JSValue, candidateWindow: CandidateWindowState
    ) {
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
    }

    private func makeConfirmEvent(
        context: InputEngineContext,
        candidate: String,
        absoluteIndex: Int,
        raw: Candidate?,
        candidateWindow: CandidateWindowState,
        sink: ActionSink
    ) -> JSValue {
        let event = JSValue(newObjectIn: jsContext)!
        event.setObject(candidate, forKeyedSubscript: "candidate" as NSString)
        event.setObject(absoluteIndex, forKeyedSubscript: "absoluteIndex" as NSString)
        if let annotation = raw?.annotation {
            event.setObject(annotation, forKeyedSubscript: "annotation" as NSString)
        }
        if let payload = raw?.payload {
            event.setObject(payload, forKeyedSubscript: "payload" as NSString)
        }
        attachEventContext(to: event, context: context, candidateWindow: candidateWindow)
        attachMutators(to: event, sink: sink)
        return event
    }

    // JSC's @convention(block) bridge stringifies JS undefined to "undefined"
    // for String? params (instead of nil). Always take optional JS args as
    // JSValue? and unwrap via this helper, which filters nil / isUndefined /
    // isNull together.
    static func resolved(_ value: JSValue?) -> JSValue? {
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
            let anchorAt = Self.optInt(opts, "anchorAt") ?? 0
            let initialHighlight = Self.optInt(opts, "initialHighlight") ?? 0
            let count = Int(itemsArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            let candidates = (0..<count).compactMap { i -> Candidate? in
                guard let item = itemsArr.objectAtIndexedSubscript(i) else { return nil }
                return Self.candidateFromJS(item)
            }
            sink.actions.append(.updateCandidates(
                candidates,
                anchorAt: anchorAt,
                initialHighlight: initialHighlight,
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
        let enterAssociatedMode: @convention(block) (String, JSValue?) -> Void = { [weak self] heldChar, candidatesValue in
            // Two-arg form uses the JS-supplied array; one-arg falls back to
            // the system AssociatedDictionary lookup.
            let candidates: [String]
            if let resolved = Self.resolved(candidatesValue),
               resolved.isArray, let arr = resolved.toArray() as? [String] {
                candidates = arr
            } else {
                candidates = heldChar.first.flatMap { self?.lookupAssociatedCandidates(for: $0) } ?? []
            }
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
