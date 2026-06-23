import CoreText
import Foundation
import OSLog

/// Process-wide view of which characters this machine's installed fonts can
/// actually render, used to filter input-method candidates down to what will
/// display. Built lazily on first use (a coverage-using engine touching
/// `shared` during its `load()`), then kept current as fonts are installed or
/// removed.
///
/// This type only answers the per-value coverage question; mapping a
/// `CoverageClass` to keep/drop under a scope policy is the consumer's job
/// (see `InputEngine.CharacterSetScope`).
///
/// Main-thread access: `classify` reads — and the font-change handler swaps —
/// the cached union on the main thread; union (re)builds run off-main.
final class FontCoverage {
    static let shared = FontCoverage()

    /// Posted when the renderable character set actually changes (font
    /// installed/removed in a way that alters coverage). Consumers holding a
    /// coverage-filtered table should re-filter. Not posted when a font change
    /// leaves the set identical.
    static let coverageDidChange = Notification.Name("FontCoverageCoverageDidChange")

    /// A value's relationship to what this machine can render.
    enum CoverageClass {
        case none           // at least one scalar no installed font can render
        case basic          // all scalars renderable and in the BMP
        case supplementary  // all scalars renderable, at least one beyond the BMP
    }

    private static let baseFontName = "PingFang TC"

    private var renderableSet: CharacterSet
    private var bitmap: Data
    private var pendingRebuild: DispatchWorkItem?

    /// The current renderable-coverage bitmap (`CharacterSet.bitmapRepresentation`),
    /// for callers that ship a snapshot elsewhere (e.g. into a JS runtime).
    /// Main-thread access, like `classify`.
    var coverageBitmap: Data { bitmap }

    private init() {
        let set = Self.buildUnion()
        renderableSet = set
        bitmap = set.bitmapRepresentation
        Logger.fontCoverage.info("Built font coverage union (\(self.bitmap.count, privacy: .public) bitmap bytes)")
        observeFontChanges()
    }

    /// Classify a candidate value (may be multiple scalars, e.g. a phrase or an
    /// IVS/emoji sequence) against the current coverage. `.none` if any scalar
    /// is unrenderable; else `.basic`/`.supplementary` by widest plane.
    func classify(_ value: String) -> CoverageClass {
        var sawSupplementary = false
        for scalar in value.unicodeScalars {
            if !renderableSet.contains(scalar) { return .none }
            if scalar.value > 0xFFFF { sawSupplementary = true }
        }
        return sawSupplementary ? .supplementary : .basic
    }

    // MARK: Union build

    /// Merge every available font's character set (system + user + admin
    /// installed; LastResort excluded) into one. Parallelized across cores —
    /// the per-font `CTFont` realization dominates and scales well; each chunk
    /// accumulates into its own `NSMutableCharacterSet` (formUnion isn't
    /// thread-safe) and the partials are merged serially.
    private static func buildUnion() -> CharacterSet {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor]) ?? []

        let chunks = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let partials = (0..<chunks).map { _ in NSMutableCharacterSet() }
        let count = descriptors.count
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * count / chunks
            let upper = (chunk + 1) * count / chunks
            let local = partials[chunk]   // distinct object per index: single writer
            for index in lower..<upper {
                let font = CTFontCreateWithFontDescriptor(descriptors[index], 16, nil)
                if (CTFontCopyPostScriptName(font) as String).contains("LastResort") { continue }
                local.formUnion(with: CTFontCopyCharacterSet(font) as CharacterSet)
            }
        }

        let merged = NSMutableCharacterSet()
        merged.formUnion(with: CTFontCopyCharacterSet(CTFontCreateWithName(baseFontName as CFString, 16, nil)) as CharacterSet)
        if let systemUIFont = CTFontCreateUIFontForLanguage(.system, 16, nil) {
            merged.formUnion(with: CTFontCopyCharacterSet(systemUIFont) as CharacterSet)
        }
        for partial in partials { merged.formUnion(with: partial as CharacterSet) }
        return merged as CharacterSet
    }

    // MARK: Font-change tracking

    private func observeFontChanges() {
        // User/admin font installs are session/persistent scope, delivered on
        // the distributed center (the local center only sees this process's own
        // registrations). See CTFontManager.h.
        DistributedNotificationCenter.default().addObserver(
            forName: .init(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild()
        }
    }

    /// Coalesce bursts (Font Book installs many files at once) into one rebuild.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func rebuild() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard self != nil else { return }
            let newSet = Self.buildUnion()
            let newBitmap = newSet.bitmapRepresentation
            DispatchQueue.main.async {
                guard let self else { return }
                guard newBitmap != self.bitmap else {
                    Logger.fontCoverage.info("Font change left coverage unchanged; no notification")
                    return
                }
                self.renderableSet = newSet
                self.bitmap = newBitmap
                Logger.fontCoverage.info("Font coverage changed; posting coverageDidChange")
                NotificationCenter.default.post(name: Self.coverageDidChange, object: nil)
            }
        }
    }
}
