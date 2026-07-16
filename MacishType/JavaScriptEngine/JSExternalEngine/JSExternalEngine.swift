import Cocoa
import Combine
import CoreServices
import OSLog
import SwiftUI

class JSExternalEngine: JavaScriptEngine {
    static let shared = JSExternalEngine()

    enum LoadStatus { case notConfigured, failed, loaded, stale }

    override var engineID: String { "JSExternal" }

    let folderBookmark = SecurityScopedBookmark(identifier: "JSExternal_engineFolder")
    private(set) var loadStatus: LoadStatus = .notConfigured

    private var folderObserver: AnyCancellable?
    private var watchStream: FSEventsWatcher?

    override var engineFolderURL: URL? { folderBookmark.url }

    override var externalSourceURL: URL? { engineFolderURL }

    override var externalDisplayName: String? {
        Self.normalizedDisplayName(manifest?.name?.resolved())
    }

    override var externalDisplayNamePublisher: AnyPublisher<String?, Never> {
        $manifest.map { Self.normalizedDisplayName($0?.name?.resolved()) }.eraseToAnyPublisher()
    }

    /// `<engineFolder>/_storage/` — sandbox scope is held for the
    /// loaded lifetime (acquire in load, release in unload), so I/O
    /// here doesn't need bridge-side scope handling.
    override var storageURL: URL? {
        guard let folder = engineFolderURL else { return nil }
        return folder.appendingPathComponent("_storage")
    }

    override var hasExternalStorageWatcher: Bool { true }

    /// Canonical path of storageURL + trailing slash, cached so each
    /// FSEvent path can be cheaply prefix-matched. Cleared whenever
    /// the folder changes (clearStoredSettings) or engine unloads.
    private var cachedStoragePathPrefix: String?

    private func storagePathPrefix() -> String? {
        if let cached = cachedStoragePathPrefix { return cached }
        guard let url = storageURL else { return nil }
        let prefix = Self.canonicalPath(for: url) + "/"
        cachedStoragePathPrefix = prefix
        return prefix
    }

    override init() {
        super.init()
        folderObserver = folderBookmark.$url
            .dropFirst()
            // @Published emits in willSet, so a plain sink runs while
            // `bookmark.url` storage is still the OLD value. Defer to next
            // runloop tick so reloadManifest sees the new value via
            // engineFolderURL.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                #if DEBUG
                Logger.javaScriptEngine.debug(
                    "JSExternal engine folder: \(self.folderBookmark.url?.path ?? "(cleared)", privacy: .public)"
                )
                #endif
                self.clearStoredSettings()
                if self.isLoaded {
                    // load() does its own reloadManifest — don't duplicate.
                    self.unload()
                    self.load()
                } else {
                    // Inactive: just refresh preview for settings UI.
                    self.reloadManifest()
                }
            }
    }

    /// Folder swap → previous manifest's storage no longer applies. Clear
    /// the manifest-settings blob and the base candidate-window / typing
    /// sub-keys; the bookmark key is preserved so folder-picker persistence
    /// survives.
    private func clearStoredSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: InputEngine.composedKey(
            engineID: engineID, subKey: InputEngine.manifestSettingsSubKey))
        defaults.removeObject(forKey: InputEngine.composedKey(
            engineID: engineID, subKey: InputEngine.manifestMenuSubKey))
        for subKey in InputEngine.resettableBaseSubKeys {
            defaults.removeObject(forKey: InputEngine.composedKey(
                engineID: engineID, subKey: subKey))
        }
        cachedStoragePathPrefix = nil
    }

    /// User picked a different folder, or a watched file changed. Don't
    /// unload yet — keep current JSContext / scope alive so the active
    /// session isn't disrupted. Next activate() detects stale and swaps.
    private func markStale(reason: String) {
        guard loadStatus == .loaded else { return }
        // .notConfigured / .failed: leave as-is; activate() retries fresh anyway.
        loadStatus = .stale
        Logger.javaScriptEngine.info(
            "engine marked stale (\(reason, privacy: .public))"
        )
    }

    override func activate(context: InputEngineContext, clientIdentifier: String?) {
        // .stale: folder changed; need fresh load on new folder. Must release
        //   OLD scope before super.activate calls load() with the NEW folder.
        // .failed: JavaScriptEngine.load() self-cleans on failure (defer),
        //   so retry just works — no special handling here.
        // .notConfigured / .loaded: no-op (super.activate's `if !isLoaded` gates).
        if loadStatus == .stale {
            unload()
        }
        super.activate(context: context, clientIdentifier: clientIdentifier)
    }

    override func load() {
        guard let folder = folderBookmark.acquire() else {
            loadStatus = .notConfigured
            // super.load() (which calls reloadManifest) won't run on this
            // short-circuit. Without an explicit re-read, an unload→load
            // chain after the bookmark is cleared leaves manifest stale —
            // engine.manifest keeps the previous folder's parsed value and
            // SwiftUI views holding it don't refresh.
            reloadManifest()
            return
        }
        super.load()
        if isModuleLoaded {
            loadStatus = .loaded
            watchStream = FSEventsWatcher(paths: [folder.path], latency: 0.5) { [weak self] paths in
                self?.handleFSEvents(paths: paths)
            }
            if watchStream == nil {
                Logger.javaScriptEngine.error(
                    "FSEvents stream creation failed for \(folder.path, privacy: .public)"
                )
            }
        } else if executionWasTerminated {
            // Runaway init loop: drop the folder so we don't re-hang on
            // every activate. The author fixes the loop and re-selects it.
            Logger.javaScriptEngine.fault(
                "engine '\(self.engineID, privacy: .public)' load timed out — clearing engine folder; fix the runaway loop and re-select it"
            )
            loadStatus = .notConfigured
            folderBookmark.clear()
        } else {
            loadStatus = .failed
            folderBookmark.release()
        }
    }

    /// Scope-per-call: pair acquire/release so settings-only invocations
    /// don't leak scope when user never enables the IME. acquire() failure
    /// (stale / revoked bookmark) short-circuits to nil so base
    /// reloadManifest sets manifest = nil without a misleading
    /// "manifest.json missing" log.
    override func readManifestFromDisk() -> (manifest: Manifest?, failure: String?) {
        guard folderBookmark.acquire() != nil else { return (nil, nil) }
        defer { folderBookmark.release() }
        return super.readManifestFromDisk()
    }

    override func unload() {
        watchStream = nil
        super.unload()
        folderBookmark.release()
        cachedStoragePathPrefix = nil
        loadStatus = .notConfigured
    }

    /// Manifest content errors (malformed JSON, invalid entry) are
    /// intentionally NOT checked here — they surface as `.failed` after
    /// load, where the status string explains the failure in context.
    nonisolated private static func manifestValidationError(_ folder: URL) -> (title: String, message: String)? {
        if Self.hasValidManifest(in: folder) { return nil }
        return (
            title: String(localized: "Invalid engine folder"),
            message: String(localized: "Selected folder must contain manifest.json")
        )
    }

    override func handleKey(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        // .stale still uses the OLD engine — passes through to super (the
        // running JS) until next activate() triggers the swap.
        if loadStatus == .loaded || loadStatus == .stale {
            return super.handleKey(
                context: context, keyEvent: keyEvent,
                candidateWindow: candidateWindow
            )
        }

        return statusPromptResult(keyEvent: keyEvent, context: context, message: statusMessage)
    }

    /// No Traditional→Simplified menu item until an engine is actually loaded.
    override var supportsSimplifiedConversion: Bool {
        (loadStatus == .loaded || loadStatus == .stale) && super.supportsSimplifiedConversion
    }

    override var settingsView: AnyView {
        AnyView(JSExternalSettingsView(engine: self))
    }

    private struct LoadFailureRow: View {
        let message: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Engine load failed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(verbatim: message)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
    }

    private struct JSExternalSettingsView: View {
        @ObservedObject var engine: JSExternalEngine

        var body: some View {
            InputEngine.settingsForm {
                BookmarkPickerSection(
                    title: "Engine folder",
                    placeholder: "Not selected",
                    buttonTitle: "Choose Folder…",
                    bookmark: engine.folderBookmark,
                    validatePick: JSExternalEngine.manifestValidationError,
                    configurePanel: { panel in
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                    }
                ) {
                    if let error = engine.lastLoadError {
                        LoadFailureRow(message: error)
                    }
                }
                if engine.lastLoadError == nil {
                    if let overrides = engine.manifest?.candidateWindow {
                        let showDirection = overrides.layoutDirection == nil
                        let showFontSize = overrides.fontSize == nil
                        if showDirection || showFontSize {
                            InputEngine.CandidateWindowSection(
                                engine: engine,
                                includeDirection: showDirection,
                                includeFontSize: showFontSize
                            )
                        }
                    } else if engine.manifest != nil {
                        InputEngine.CandidateWindowSection(engine: engine)
                    }
                    JavaScriptEngine.EngineSettingsRenderer(
                        engine: engine,
                        sections: engine.manifest?.settings
                    )
                }
            }
            .onAppear {
                // Inactive engine: re-read disk on every tab entry (FSEvents
                // only watches once .loaded, so no markStale path applies
                // here). Stale engine: force swap so it catches up.
                if !engine.isLoaded {
                    engine.reloadManifest()
                } else if engine.loadStatus == .stale {
                    engine.unload()
                    engine.load()
                }
            }
        }
    }

    private var statusMessage: String {
        switch loadStatus {
        case .notConfigured:
            return String(localized: "Choose engine folder")
        case .failed:
            return String(localized: "Engine load failed")
        case .loaded, .stale:
            return ""
        }
    }

    /// Editor / metadata noise that's never in `loadedFilePaths` and
    /// should short-circuit before paying the `canonicalPath` syscall.
    /// `_storage/` paths get explicit routing in `handleFSEvents`
    /// (not here) so they reach the storage event pipeline.
    nonisolated private static func isFSEventsNoise(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") { return true }
        if name.hasSuffix("~") { return true }
        return false
    }

    /// `_storage/` paths route to the storage-event pipeline; other
    /// import-graph hits trigger reload via markStale.
    private func handleFSEvents(paths: [String]) {
        let storagePrefix = storagePathPrefix()
        var trackedHit: String?
        for path in paths {
            // Substring pre-check is cheap; only canonicalize when
            // the path is a storage candidate or could be a tracked
            // import. .DS_Store et al. short-circuit before realpath.
            let maybeStorage = path.contains("/_storage/")
            if !maybeStorage && Self.isFSEventsNoise(path) { continue }
            let canonical = Self.canonicalPath(for: URL(fileURLWithPath: path))
            if maybeStorage, let storagePrefix,
               canonical.hasPrefix(storagePrefix) {
                handleStorageEvent(path: path)
                continue
            }
            // Keep scanning — the batch may still carry storage events.
            if trackedHit == nil, loadedFilePaths.contains(canonical) {
                trackedHit = path
            }
        }
        if let trackedHit { markStale(reason: "tracked file changed: \(trackedHit)") }
    }
}
