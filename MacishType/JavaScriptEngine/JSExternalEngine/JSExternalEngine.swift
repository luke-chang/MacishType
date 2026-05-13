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
    private var watchStream: FSEventStreamRef?

    override var engineFolderURL: URL? { folderBookmark.url }

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
    /// the manifest-settings blob and the base candidate-window / associated
    /// sub-keys; the bookmark key is preserved so folder-picker persistence
    /// survives.
    private func clearStoredSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: InputEngine.composedKey(
            engineID: engineID, subKey: InputEngine.manifestSettingsSubKey))
        for subKey in [
            InputEngine.directionSubKey,
            InputEngine.fontSizeSubKey,
            InputEngine.showAssociatedWordsSubKey,
        ] {
            defaults.removeObject(forKey: InputEngine.composedKey(
                engineID: engineID, subKey: subKey))
        }
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
            startWatching(folder: folder)
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
    override func readManifestFromDisk() -> Manifest? {
        guard folderBookmark.acquire() != nil else { return nil }
        defer { folderBookmark.release() }
        return super.readManifestFromDisk()
    }

    override func unload() {
        stopWatching()
        super.unload()
        folderBookmark.release()
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
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        // .stale still uses the OLD engine — passes through to super (the
        // running JS) until next activate() triggers the swap.
        if loadStatus == .loaded || loadStatus == .stale {
            return super.handleKey(
                context: context, keyCode: keyCode,
                characters: characters, modifiers: modifiers,
                candidateWindow: candidateWindow
            )
        }

        let pure = modifiers.intersection(.deviceIndependentFlagsMask)

        if !pure.intersection([.command, .control]).isEmpty {
            return context.isComposing ? .handled() : .notHandled
        }
        // Esc / Backspace clear the displayed status.
        if keyCode == 53 || keyCode == 51 {
            return context.isComposing ? .handled([.resetContext]) : .notHandled
        }
        return .handled([.updateMarkedText(statusMessage)])
    }

    override var settingsView: AnyView {
        AnyView(JSExternalSettingsView(engine: self))
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
                    validatePick: JSExternalEngine.manifestValidationError
                ) { panel in
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                }
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

    // MARK: - FSEvents watcher

    private func startWatching(folder: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // UseCFTypes: eventPaths arrives as CFArray<CFString> instead of a
        // C-string vector — far easier to bridge into Swift.
        // Stream is queued to .main below, so the callback runs on main —
        // `assumeIsolated` is safe.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let engine = Unmanaged<JSExternalEngine>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { engine.handleFSEvents(paths: paths) }
        }
        // TODO(when fs API ships): exclude self-write subpaths so the engine's
        // own user-dict writes don't trigger markStale → reload → wipe
        // learned state. Currently no fs API in runtime.js, so always-on is
        // safe.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            Logger.javaScriptEngine.error(
                "FSEvents stream creation failed for \(folder.path, privacy: .public)"
            )
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        watchStream = stream
    }

    private func stopWatching() {
        if let stream = watchStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        watchStream = nil
    }

    /// Early short-circuit for high-frequency FSEvents noise — macOS
    /// metadata, dotfiles, editor backups — so we skip the canonical-path
    /// syscall for them. The authoritative relevance check is
    /// `loadedFilePaths` containment.
    nonisolated private static func isFSEventsNoise(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") { return true }   // hidden / editor temp (.swp, .tmp)
        if name.hasSuffix("~") { return true }   // editor backups
        return false
    }

    /// Marks the engine stale only when a file that was actually read during
    /// the last load is touched. Files outside the import graph (notes,
    /// drafts, future engine-owned data) are ignored.
    private func handleFSEvents(paths: [String]) {
        let tracked = loadedFilePaths
        let hit = paths.first { path in
            !Self.isFSEventsNoise(path)
                && tracked.contains(Self.canonicalPath(for: URL(fileURLWithPath: path)))
        }
        guard let hit else { return }
        markStale(reason: "tracked file changed: \(hit)")
    }
}
