import Cocoa
import Combine
import CoreServices
import OSLog
import SwiftUI

class JSExternalEngine: JavaScriptEngine {
    static let shared = JSExternalEngine()

    enum LoadStatus { case notConfigured, failed, loaded, stale }

    override class var engineID: String { "JSExternal" }

    let folderBookmark = SecurityScopedBookmark(identifier: "JSExternal_engineFolder")
    private(set) var loadStatus: LoadStatus = .notConfigured

    private static let manifestFileName = "manifest.json"

    // Static is OK because JSExternalEngine is process-wide singleton
    // (`static let shared`); if we ever support multiple JS engines with
    // different entries, these need to be per-instance + entryScriptURL /
    // importRoot promoted from class var to instance.
    private static var resolvedEntry: URL?
    private static var resolvedFolder: URL?

    private var folderObserver: AnyCancellable?
    private var watchStream: FSEventStreamRef?

    override class var entryScriptURL: URL? { resolvedEntry }
    // Picked folder, not entry parent — manifest may put entry in a subdir
    // (e.g. "src/index.js") but the user granted scope on the whole folder.
    override class var importRoot: URL? { resolvedFolder }

    override init() {
        super.init()
        folderObserver = folderBookmark.$url
            .dropFirst()
            .sink { [weak self] _ in self?.markStale(reason: "folder picker changed") }
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
            return
        }
        guard let entry = Self.resolveEntryFromManifest(folder: folder) else {
            folderBookmark.release()
            loadStatus = .failed
            return
        }
        Self.resolvedEntry = entry
        Self.resolvedFolder = folder
        super.load()
        if isModuleLoaded {
            loadStatus = .loaded
            startWatching(folder: folder)
        } else {
            loadStatus = .failed
            folderBookmark.release()
        }
    }

    override func unload() {
        stopWatching()
        super.unload()
        folderBookmark.release()
        Self.resolvedEntry = nil
        Self.resolvedFolder = nil
        loadStatus = .notConfigured
    }

    private static func resolveEntryFromManifest(folder: URL) -> URL? {
        let manifestURL = folder.appending(path: manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            Logger.javaScriptEngine.error(
                "manifest.json missing in \(folder.path, privacy: .public)"
            )
            return nil
        }
        #if DEBUG
        Logger.javaScriptEngine.debug(
            "loaded manifest: \(manifestURL.path, privacy: .public)"
        )
        #endif
        struct Manifest: Decodable { let entry: String }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            Logger.javaScriptEngine.error(
                "manifest.json malformed in \(folder.path, privacy: .public)"
            )
            return nil
        }
        return folder.appending(path: manifest.entry)
    }

    /// Manifest content errors (malformed JSON, invalid entry) are
    /// intentionally NOT checked here — they surface as `.failed` after
    /// load, where the status string explains the failure in context.
    private static func manifestValidationError(_ folder: URL) -> (title: String, message: String)? {
        let manifestURL = folder.appending(path: manifestFileName)
        if FileManager.default.fileExists(atPath: manifestURL.path) { return nil }
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
            return context.isComposing ? .handled([.noop]) : .notHandled
        }
        // Esc / Backspace clear the displayed status.
        if keyCode == 53 || keyCode == 51 {
            return context.isComposing ? .handled([.resetContext]) : .notHandled
        }
        return .handled([.updateMarkedText(statusMessage)])
    }

    override var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                BookmarkPickerSection(
                    title: "Engine folder",
                    placeholder: "Not selected",
                    buttonTitle: "Choose Folder…",
                    bookmark: folderBookmark,
                    validatePick: Self.manifestValidationError
                ) { panel in
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                }
                InputEngine.CandidateWindowSection(engineType: Self.self)
            }
        )
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
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            guard let firstRelevant = paths.first(where: JSExternalEngine.isRelevantPath) else { return }
            let engine = Unmanaged<JSExternalEngine>.fromOpaque(info).takeUnretainedValue()
            engine.markStale(reason: "file changed: \(firstRelevant)")
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

    /// Filters FSEvents noise: macOS metadata, dotfiles, editor backups.
    /// Anything else is treated as engine-relevant and triggers markStale.
    private static func isRelevantPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return false }
        if name.hasPrefix(".") { return false }   // hidden / editor temp (.swp, .tmp)
        if name.hasSuffix("~") { return false }   // editor backups
        return true
    }
}
