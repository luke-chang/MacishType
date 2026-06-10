import Carbon
import Cocoa
import OSLog
import SwiftUI

// MARK: - Per-Client State

class InputEngineContext {
    // Controller mirrors emitted .updateMarkedText into this field, so engines
    // that don't keep their own composing buffer can read marked text here.
    // Engines must mutate this only via the action stream.
    var markedText: String = ""

    var isComposing: Bool { !markedText.isEmpty }

    // Prefix of marked text that the engine has declared as "confirmed, pending
    // commit" via .updateMarkedText(staged:). Flushed on deactivate / .flushStaged.
    var stagedText: String = ""

    // True between paired engine.activate/deactivate hooks (not derivable).
    var isActivated: Bool = false

    // Controller-driven associated mode. Engines opt-in by emitting
    // .enterAssociatedMode; Controller manages the key flow while this is true.
    // Engines wanting full customization should NOT set this and implement
    // their own state machine.
    var isAssociating: Bool = false

    func reset() {
        markedText = ""
        stagedText = ""
        isAssociating = false
    }
}

// MARK: - Candidate Window State (read-only snapshot)

/// Read-only snapshot passed into `handleKey` so engines decide without
/// mutating the window.
struct CandidateWindowState {
    let isVisible: Bool
    let configuration: CandidateWindowConfiguration
}

// MARK: - Engine Action

enum EngineAction {
    // staged: leading chars confirmed for commit on session end (negative = whole text).
    case updateMarkedText(String, cursor: Int? = nil, emphasis: Range<Int>? = nil, staged: Int = 0)
    // `anchorAt`: cursor position in markedText (0...markedText.count)
    // where the window's left edge anchors. `initialHighlight`: 0 =
    // first candidate; n > 0 = absolute index (clamped); negative = no
    // selection. `configure` overrides engine default per-update; nil
    // keeps the engine default.
    case updateCandidates([Candidate], anchorAt: Int = 0, initialHighlight: Int = 0,
                          configure: ((inout CandidateWindowConfiguration) -> Void)? = nil)
    // Engine-confirmed candidate: routes through engine.candidateConfirmed.
    case commit(Candidate)
    case commitSelectedCandidate
    case commitCandidateAtIndex(Int)
    case navigateCandidates(NavigationDirection, wrapping: Bool = false)
    // Discard-all intent: clear marked text, hide candidate window, reset context.
    case resetContext
    // Keep-confirmed intent: commit stagedText concatenated with the given
    // append string (both may be empty) via a single insertText call, then
    // hide window and reset context.
    case flushStaged(String = "")
    // Enter associated mode: held char becomes staged marked text,
    // candidates are displayed with anchorAt=1 initialHighlight=-1. Payload
    // carries pre-looked-up candidates so Controller doesn't re-query.
    case enterAssociatedMode(String, [String])
}

enum EngineHandleResult {
    case handled([EngineAction] = [])
    case notHandled([EngineAction] = [])
}

extension EngineAction {
    /// Convenience for engines that emit candidates as bare strings — wraps
    /// each into `Candidate(_:)` with no annotation. Existing call sites
    /// dispatch here via parameter type inference; sites that want
    /// annotations construct `[Candidate]` directly and hit the case above.
    static func updateCandidates(
        _ texts: [String],
        anchorAt: Int = 0,
        initialHighlight: Int = 0,
        configure: ((inout CandidateWindowConfiguration) -> Void)? = nil
    ) -> EngineAction {
        .updateCandidates(
            texts.map { Candidate($0) },
            anchorAt: anchorAt,
            initialHighlight: initialHighlight,
            configure: configure
        )
    }

    /// Empty candidates payload — controller hides the candidate window
    /// when this is processed. Use when an engine wants to clear pending
    /// candidates while keeping marked text active.
    static let clearCandidates: EngineAction = .updateCandidates([] as [Candidate])

    static func commit(_ text: String) -> EngineAction {
        .commit(Candidate(text))
    }
}

// MARK: - Base Engine

/// Raw keyboard event payload threaded from InputController into the engine
/// protocol. Bundled so `handleKey` and its helpers can grow new fields
/// without rippling parameter lists across every override.
struct KeyEventInput {
    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool

    /// Modifier flags with device-dependent bits stripped.
    var pureModifiers: NSEvent.ModifierFlags { modifiers.intersection(.deviceIndependentFlagsMask) }

    /// No Cmd/Ctrl/Option/Shift held — nothing that changes the key's meaning,
    /// so a control key may perform its action. (CapsLock / Fn are ignored.)
    var isBareKey: Bool { pureModifiers.isDisjoint(with: [.command, .control, .option, .shift]) }
}

class InputEngine {

    // MARK: Engine Registry (static)

    private static let engines: [String: () -> InputEngine] = [
        "Example": { ExampleEngine.shared },
        "Array": { ArrayEngine.shared },
        "JSExternal": { JSExternalEngine.shared },
    ]

    static func engine(for inputModeID: String) -> InputEngine? {
        guard let prefix = Bundle.main.bundleIdentifier,
              inputModeID.hasPrefix(prefix + ".") else { return nil }
        let suffix = String(inputModeID.dropFirst(prefix.count + 1))
        return engines[suffix]?()
    }

    static func engine(forSuffix suffix: String) -> InputEngine? {
        engines[suffix]?()
    }

    /// UserDefaults key: `{engineID}_{subKey}`.
    static func composedKey(engineID: String, subKey: String) -> String {
        "\(engineID)_\(subKey)"
    }

    nonisolated static let directionSubKey = "candidateWindowDirection"
    nonisolated static let fontSizeSubKey = "candidateWindowFontSize"
    nonisolated static let enableAssociatedModeSubKey = "enableAssociatedMode"
    nonisolated static let manifestSettingsSubKey = "manifestSettings"

    /// Per-instance: same class may have multiple instances with distinct
    /// IDs (e.g. multi-slot subclasses). Subclass override required;
    /// `InputEngine` is abstract.
    var engineID: String { fatalError("Subclasses must override") }

    /// BCP47 language tag from Info.plist's `ComponentInputModeDict` entry
    /// for this engine. nil if the entry or `TISIntendedLanguage` key is
    /// missing (a misconfiguration; logged as .fault). Cached.
    private lazy var plistIntendedLanguage: String? = {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let comp = Bundle.main.infoDictionary?["ComponentInputModeDict"] as? [String: Any],
              let list = comp["tsInputModeListKey"] as? [String: [String: Any]],
              let entry = list["\(bundleID).\(engineID)"],
              let lang = entry["TISIntendedLanguage"] as? String
        else {
            Logger.inputEngine.fault("No TISIntendedLanguage for engine \"\(self.engineID, privacy: .public)\" — check Info.plist ComponentInputModeDict")
            return nil
        }
        return lang
    }()

    /// Resolved BCP47 language tag for this engine. Base resolves from
    /// Info.plist's `ComponentInputModeDict`; subclasses may override to
    /// layer their own source (e.g. a manifest declaration) on top.
    var intendedLanguage: String? { plistIntendedLanguage }

    // Defaults below are per-class — same value across all instances of a
    // given subclass, hence `class var`.
    class var defaultDirection: CandidateWindow.LayoutDirection { .horizontal }
    class var defaultFontSize: Int { 16 }
    class var defaultEnableAssociatedMode: Bool { false }

    // MARK: Input Source Monitoring

    private(set) static var enabledEngines: Set<String> = []
    private static var pendingWorkItem: DispatchWorkItem?

    static func observeEnabledEngines() {
        enabledEngines = queryEnabledEngines()
        #if DEBUG
        Logger.inputEngine.debug("Initial enabled engines: \(enabledEngines.sorted(), privacy: .public)")
        #endif

        DistributedNotificationCenter.default().addObserver(
            forName: .init(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            Self.pendingWorkItem?.cancel()
            let item = DispatchWorkItem { Self.updateEnabledEngines() }
            Self.pendingWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    private static func queryEnabledEngines() -> Set<String> {
        let bundleID = Bundle.main.bundleIdentifier!
        let conditions = [
            kTISPropertyBundleID as String: bundleID,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(conditions, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        let ids = sources.compactMap { source in
            TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        }
        let prefix = bundleID + "."
        guard ids.contains(bundleID) else { return [] }
        return Set(ids.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }

    private static func updateEnabledEngines() {
        let newEngines = queryEnabledEngines()
        guard newEngines != enabledEngines else { return }
        let removed = enabledEngines.subtracting(newEngines)
        enabledEngines = newEngines
        #if DEBUG
        Logger.inputEngine.debug("Enabled engines: \(newEngines.sorted(), privacy: .public)")
        #endif
        for key in removed {
            if let engine = engines[key]?(), engine.isLoaded {
                #if DEBUG
                Logger.inputEngine.debug("Unloading engine: \("\(type(of: engine))", privacy: .public)")
                #endif
                engine.unload()
            }
        }
    }

    // MARK: Engine Instance

    // Stored property initializers can't use `Self`, so they reference the
    // base class default. `init()` then calls `reloadConfig()` which picks
    // up `Self.defaultX` overrides and any persisted UserDefaults value.
    var candidateWindowDirection: CandidateWindow.LayoutDirection = InputEngine.defaultDirection
    var candidateWindowFontSize: Int = InputEngine.defaultFontSize
    var enableAssociatedMode: Bool = InputEngine.defaultEnableAssociatedMode

    private var associatedDictionaryHandle: AssociatedDictionary.Handle?

    init() {
        reloadConfig()
    }

    /// Subclasses override to also reload their own keys; call `super` first.
    func reloadConfig() {
        candidateWindowDirection = defaultsValue(Self.directionSubKey, fallback: Self.defaultDirection)
        candidateWindowFontSize = defaultsValue(Self.fontSizeSubKey, fallback: Self.defaultFontSize)
        enableAssociatedMode = defaultsValue(Self.enableAssociatedModeSubKey, fallback: Self.defaultEnableAssociatedMode)
    }

    private func defaultsValue<T>(_ subKey: String, fallback: T) -> T {
        let key = Self.composedKey(engineID: self.engineID, subKey: subKey)
        return (UserDefaults.standard.object(forKey: key) as? T) ?? fallback
    }

    private func defaultsValue<T: RawRepresentable>(_ subKey: String, fallback: T) -> T
        where T.RawValue == String
    {
        let key = Self.composedKey(engineID: self.engineID, subKey: subKey)
        return UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    // MARK: Factory

    func createContext() -> InputEngineContext { InputEngineContext() }

    // MARK: Lifecycle

    private(set) var isLoaded = false

    /// Subclass setup. Override to perform initialization, then call
    /// `super.load()` to mark the engine loaded and acquire the associated
    /// dictionary. Skipping `super.load()` (e.g. on failure) keeps
    /// `isLoaded == false` and acquires no handle, so the next `activate()`
    /// retries.
    func load() {
        isLoaded = true
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
    }

    /// Subclass cleanup. Override to release resources, then call
    /// `super.unload()` to release the associated dictionary and clear
    /// `isLoaded`.
    func unload() {
        associatedDictionaryHandle = nil
        isLoaded = false
    }

    // Override for per-session setup. Loads engine on first call.
    func activate(context: InputEngineContext, clientIdentifier: String?) {
        reloadConfig()
        if !isLoaded {
            #if DEBUG
            Logger.inputEngine.debug("Loading engine: \("\(type(of: self))", privacy: .public)")
            #endif
            load()
        }
        // Catches toggle changes from between sessions — load() runs only once.
        reconcileAssociatedDictionary(handle: &associatedDictionaryHandle)
    }

    // Override for per-session cleanup (persist learning model, flush caches).
    // Must NOT touch marked text or candidate window — controller handles those.
    func deactivate(context: InputEngineContext, clientIdentifier: String?) {
    }

    // MARK: Event Handling

    func handleKey(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        let pureMods = keyEvent.pureModifiers

        if !pureMods.intersection([.command, .control]).isEmpty {
            return context.isComposing ? .handled() : .notHandled()
        }

        // Text-producing combos run before the modified-key rule below.
        if !pureMods.contains(.option),
           let text = keyEvent.characters, text.count == 1,
           let char = text.first, char.isUppercase, char.isLetter {
            return context.isComposing ? .handled() : .handled([.flushStaged(text)])
        }

        // charactersIgnoringModifiers is layout-aware and carries Shift, so
        // Option+Shift → fullwidth uppercase / symbols.
        if pureMods.contains(.option),
           let chars = keyEvent.charactersIgnoringModifiers,
           chars.count == 1, let char = chars.first,
           let fullwidth = Self.toFullwidth(char) {
            return context.isComposing ? .handled() : .handled([.flushStaged(String(fullwidth))])
        }

        if !keyEvent.isBareKey {
            return context.isComposing ? .handled() : .notHandled()
        }

        if keyEvent.keyCode == KeyCode.escape {
            return context.isComposing ? .handled([.flushStaged()]) : .notHandled()
        }

        return .notHandled()
    }

    /// Associated-mode key handler. `.notHandled` dismisses associated
    /// mode (flushStaged) and re-dispatches the key via `handleKey`.
    /// Default impl: Escape dismisses; everything else falls through.
    func handleAssociatedKey(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> EngineHandleResult {
        if keyEvent.keyCode == KeyCode.escape {
            return .handled([.flushStaged()])
        }
        return .notHandled()
    }

    /// While composing, asks whether this key should flush the staged text
    /// first: returning true commits it (full teardown) and re-dispatches the
    /// key to `handleKey` on a fresh context. Default: false.
    func shouldFlushStagedBeforeHandling(
        context: InputEngineContext,
        keyEvent: KeyEventInput,
        candidateWindow: CandidateWindowState
    ) -> Bool {
        false
    }

    func candidateConfirmed(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate?,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        if context.isAssociating {
            return [.flushStaged(candidate)]
        }
        if enableAssociatedMode,
           candidate.count == 1, let first = candidate.first {
            let related = lookupAssociatedCandidates(for: first)
            if !related.isEmpty {
                return [.enterAssociatedMode(candidate, related)]
            }
        }
        return [.flushStaged(candidate)]
    }

    func candidateSelectionChanged(
        context: InputEngineContext, _ candidate: String, absoluteIndex: Int, raw: Candidate,
        candidateWindow: CandidateWindowState
    ) -> [EngineAction] {
        []
    }

    // MARK: Subclass Override Points

    /// Settings UI; subclasses override to add their own sections.
    var settingsView: AnyView {
        AnyView(
            InputEngine.settingsForm {
                InputEngine.CandidateWindowSection(engine: self)
            }
        )
    }

    var candidateWindowConfiguration: CandidateWindowConfiguration {
        .init(
            layoutDirection: candidateWindowDirection,
            fontSize: CGFloat(candidateWindowFontSize)
        )
    }

    // Associated-phrase lookup backed by the locale-keyed associated
    // dictionary. The handle is non-nil only when the engine has opted in
    // (enableAssociatedMode) and a dictionary for its locale is bundled.
    func lookupAssociatedCandidates(for char: Character) -> [String] {
        associatedDictionaryHandle?.lookup(char) ?? []
    }

    // MARK: Utilities

    static func toFullwidth(_ char: Character) -> Character? {
        if char == " " { return "\u{3000}" }
        guard let ascii = char.asciiValue, ascii >= 0x21, ascii <= 0x7E else { return nil }
        return Character(UnicodeScalar(UInt32(ascii) + 0xFEE0)!)
    }

}

// MARK: - SwiftUI Settings Helpers

extension InputEngine {
    /// Wraps content in the project's standard settings Form chrome:
    /// `.formStyle(.grouped)` + `.padding(.top, -20)` to cancel the 20pt
    /// top padding baked into grouped Form (see memory:
    /// swiftui-form-grouped-top-padding).
    static func settingsForm<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .padding(.top, -20)
    }

    /// Engines pass `engine: self` so the `@AppStorage` fallback dispatches
    /// through `defaultDirection` / `defaultFontSize` overrides (via
    /// metatype), staying in lockstep with `reloadConfig`.
    struct CandidateWindowSection: View {
        let title: LocalizedStringKey
        let includeDirection: Bool
        let includeFontSize: Bool

        @AppStorage private var direction: CandidateWindow.LayoutDirection
        @AppStorage private var fontSize: Int

        init(
            engine: InputEngine,
            title: LocalizedStringKey = "Candidate window",
            includeDirection: Bool = true,
            includeFontSize: Bool = true
        ) {
            self.title = title
            self.includeDirection = includeDirection
            self.includeFontSize = includeFontSize
            self._direction = AppStorage(
                wrappedValue: type(of: engine).defaultDirection,
                InputEngine.composedKey(engineID: engine.engineID, subKey: InputEngine.directionSubKey))
            self._fontSize = AppStorage(
                wrappedValue: type(of: engine).defaultFontSize,
                InputEngine.composedKey(engineID: engine.engineID, subKey: InputEngine.fontSizeSubKey))
        }

        var body: some View {
            // Avoid an empty Section header when caller didn't gate.
            if includeDirection || includeFontSize {
                Section(title) {
                    if includeDirection {
                        Picker("Orientation:", selection: $direction) {
                            Text("Horizontal").tag(CandidateWindow.LayoutDirection.horizontal)
                            Text("Vertical").tag(CandidateWindow.LayoutDirection.vertical)
                        }
                    }
                    if includeFontSize {
                        Picker("Font size:", selection: $fontSize) {
                            ForEach([14, 16, 18, 24, 36], id: \.self) {
                                Text(verbatim: "\($0)").tag($0)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Toggle for the associated mode opt-in. Engines opting in to the
    /// feature include this in their `settingsView`.
    struct EnableAssociatedModeToggle: View {
        @AppStorage private var value: Bool

        init(engine: InputEngine, defaultOverride: Bool? = nil) {
            self._value = AppStorage(
                wrappedValue: defaultOverride ?? type(of: engine).defaultEnableAssociatedMode,
                InputEngine.composedKey(engineID: engine.engineID, subKey: InputEngine.enableAssociatedModeSubKey))
        }

        var body: some View {
            Toggle("Show predictive completions", isOn: $value)
        }
    }
}
