import Cocoa
import Combine
import CoreServices
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// CIN engine that loads a user-picked `.cin` file (security-scoped) and
/// hot-reloads it on edit.
final class CINExternalEngine: CINEngine, ObservableObject {
    static let shared = CINExternalEngine()

    override var engineID: String { "CINExternal" }

    /// The loaded table's display name (`%cname`/`%ename`), published so the
    /// Settings window title tracks it. nil when no table is loaded.
    @Published private(set) var displayName: String?

    let fileBookmark = SecurityScopedBookmark(identifier: "CINExternal_tableFile")

    private var fileObserver: AnyCancellable?
    private var coverageObserver: (any NSObjectProtocol)?
    private var watchStream: FSEventStreamRef?
    private var watchedCanonicalPath: String?

    /// Set when the watched file changes mid-session; the reload is deferred
    /// to the next `activate()` so it never swaps the table while the user is
    /// composing.
    private var isStale = false

    override var cinTableURL: URL? { fileBookmark.url }

    override init() {
        super.init()
        fileObserver = fileBookmark.$url
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // A newly picked table is a fresh input method: reset settings
                // to defaults. Clear synchronously (on the willSet) so Settings
                // never shows the new file with the old table's options; the new
                // URL is stored only after this returns, so defer the parse.
                self.replaceTable(nil)
                self.clearTableSettings()
                self.reloadConfig()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isLoaded {
                        self.unload()
                        self.load()
                    } else {
                        self.refreshTableForSettings()
                    }
                }
            }
        // Font install/removal can change which scopes a table offers; refresh
        // the picker (filtering is at-lookup, so it stays current on its own).
        coverageObserver = NotificationCenter.default.addObserver(
            forName: FontCoverage.coverageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidateScopeAvailability()
            self.objectWillChange.send()
        }
    }

    /// Reset this engine's persisted settings to defaults — the candidate
    /// window / typing base keys plus the CIN preview-mode key (a newly loaded
    /// table is a fresh slate).
    private func clearTableSettings() {
        let defaults = UserDefaults.standard
        for subKey in InputEngine.resettableBaseSubKeys + [CINEngine.previewCandidatesSubKey] {
            defaults.removeObject(forKey: InputEngine.composedKey(engineID: engineID, subKey: subKey))
        }
    }

    // MARK: - Lifecycle (scope held for the loaded lifetime)

    /// A stale table (watched file edited) is swapped here rather than on the
    /// FSEvent itself, so an in-progress composition is never disrupted.
    override func activate(context: InputEngineContext, clientIdentifier: String?) {
        if isStale {
            isStale = false
            if isLoaded { unload() }
        }
        super.activate(context: context, clientIdentifier: clientIdentifier)
    }

    /// Parse with the security scope held (acquired by the caller or here).
    override func refreshTableForSettings() {
        guard table == nil, fileBookmark.acquire() != nil else { return }
        defer { fileBookmark.release() }
        loadTableIfNeeded()
    }

    override func load() {
        isStale = false
        guard fileBookmark.acquire() != nil else { return }
        loadTableIfNeeded()
        guard table != nil else {
            fileBookmark.release()
            return
        }
        super.load()
        if let url = fileBookmark.url { startWatching(fileURL: url) }
    }

    override func unload() {
        stopWatching()
        super.unload()
        fileBookmark.release()
    }

    override func replaceTable(_ newTable: CINTable?) {
        // The Settings view reads `table` directly, so notify observers of the
        // change explicitly rather than leaning on the displayName publisher.
        objectWillChange.send()
        super.replaceTable(newTable)
        displayName = newTable.flatMap { $0.cname ?? $0.ename }
    }

    /// No Traditional→Simplified menu item until a table is actually loaded.
    override var supportsSimplifiedConversion: Bool {
        table != nil && super.supportsSimplifiedConversion
    }

    /// Watched file changed: defer the reload to the next `activate()` (keeps
    /// the running table until the user is between compositions).
    private func markStale() {
        guard isLoaded else { return }
        isStale = true
        Logger.inputEngine.info("CINExternal table marked stale (file changed)")
    }

    // MARK: - Key handling (status prompt when no table)

    override func handleKey(
        context: InputEngineContext, keyEvent: KeyEventInput, candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        if table != nil {
            return super.handleKey(
                context: context, keyEvent: keyEvent, candidateWindow: candidateWindow)
        }
        // No usable table: show a prompt instead of composing. Non-printing keys
        // pass through when idle so the user can still type / navigate.
        let pure = keyEvent.pureModifiers
        if !pure.intersection([.command, .control]).isEmpty {
            return context.isComposing ? .handled() : .notHandled()
        }
        if keyEvent.keyCode == KeyCode.escape || keyEvent.keyCode == KeyCode.backspace {
            return context.isComposing ? .handled([.resetContext]) : .notHandled()
        }
        if !Self.isPrintingKey(keyEvent.characters), !context.isComposing {
            return .notHandled()
        }
        return .handled([.updateMarkedText(statusMessage)])
    }

    private var statusMessage: String {
        cinTableURL == nil
            ? String(localized: "Select a CIN table")
            : String(localized: "CIN table load failed")
    }

    /// Visible-text keys only — excludes control chars, space, DEL, and the
    /// function-key private-use range (arrows, F-keys, Page, Home/End).
    nonisolated private static func isPrintingKey(_ characters: String?) -> Bool {
        guard let scalar = characters?.unicodeScalars.first else { return false }
        switch scalar.value {
        case ..<0x21, 0x7F, 0xF700...0xF8FF: return false
        default: return true
        }
    }

    // MARK: - Settings

    override var settingsView: AnyView {
        AnyView(CINExternalSettingsView(engine: self))
    }

    nonisolated fileprivate static func validatePick(_ url: URL) -> (title: String, message: String)? {
        if CINTable(contentsOf: url) != nil { return nil }
        return (
            title: String(localized: "Invalid CIN table"),
            message: String(localized: "The selected file is not a valid .cin table.")
        )
    }

    // MARK: - FSEvents watcher

    private func startWatching(fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        watchedCanonicalPath = Self.canonicalPath(for: fileURL)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let engine = Unmanaged<CINExternalEngine>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { engine.handleFSEvents(paths: paths) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            Logger.inputEngine.error("CINExternal FSEvents creation failed for \(directory.path, privacy: .public)")
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
        watchedCanonicalPath = nil
    }

    private func handleFSEvents(paths: [String]) {
        guard let target = watchedCanonicalPath else { return }
        for path in paths where Self.canonicalPath(for: URL(fileURLWithPath: path)) == target {
            markStale()
            break
        }
    }

    nonisolated private static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct CINExternalSettingsView: View {
    // Observe the engine so the sections re-derive whenever the table changes
    // (replaceTable fires objectWillChange; the deferred fileObserver re-parses
    // after a file swap).
    @ObservedObject var engine: CINExternalEngine
    @ObservedObject var bookmark: SecurityScopedBookmark

    init(engine: CINExternalEngine) {
        self.engine = engine
        self.bookmark = engine.fileBookmark
    }

    var body: some View {
        let table = engine.table
        let availability = engine.scopeAvailability
        InputEngine.settingsForm {
            BookmarkPickerSection(
                title: "CIN table",
                placeholder: "Not selected",
                buttonTitle: "Choose File…",
                bookmark: bookmark,
                validatePick: CINExternalEngine.validatePick
            ) { panel in
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                if let cinType = UTType(filenameExtension: "cin") {
                    panel.allowedContentTypes = [cinType]
                }
            }
            // Other options only make sense once a table is loaded.
            if table != nil {
                InputEngine.CandidateWindowSection(engine: engine)
                Section("Typing") {
                    InputEngine.EnableAssociatedModeToggle(engine: engine)
                    if table?.isPreviewable == true {
                        CINPreviewCandidatesToggle(engine: engine)
                    }
                    if availability.showsPicker {
                        InputEngine.CharacterSetScopePicker(engine: engine, availability: availability)
                    }
                }
            }
        }
        // Parse for display when opened inactive; file changes are handled by
        // the engine's fileObserver (which republishes the table).
        .onAppear { engine.refreshTableForSettings() }
    }
}
