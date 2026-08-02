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
/// Main-actor isolated; state is main-confined. The union is built off-main
/// (preheat at launch, or rebuild on font change) and installed on main; a
/// query before the preheat finishes builds it synchronously (`ensureBuilt`).
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

    /// True once the union is built. Main-confined; guards the one-time
    /// build across `ensureBuilt` / `preheat` / `rebuild`.
    private var isReady = false

    /// The current renderable-coverage bitmap (`CharacterSet.bitmapRepresentation`),
    /// for callers that ship a snapshot elsewhere (e.g. into a JS runtime).
    /// Not a pure read: triggers a synchronous build on first access if the
    /// preheat hasn't finished (see `ensureBuilt`).
    var coverageBitmap: Data { ensureBuilt(); return bitmap }

    private init() {
        // Built lazily off-main (preheat / ensureBuilt), not here, so
        // touching `.shared` never blocks.
        renderableSet = CharacterSet()
        bitmap = Data()
        observeFontChanges()
    }

    /// Classify a candidate value (may be multiple scalars, e.g. a phrase or an
    /// IVS/emoji sequence) against the current coverage. `.none` if any scalar
    /// is unrenderable; else `.basic`/`.supplementary` by widest plane.
    func classify(_ value: String) -> CoverageClass {
        ensureBuilt()
        var sawSupplementary = false
        for scalar in value.unicodeScalars {
            if !renderableSet.contains(scalar) { return .none }
            if scalar.value > 0xFFFF { sawSupplementary = true }
        }
        return sawSupplementary ? .supplementary : .basic
    }

    // MARK: Build lifecycle

    /// Build synchronously on the calling thread if the preheat hasn't
    /// installed a union yet, so callers never read empty coverage. No-op once ready.
    private func ensureBuilt() {
        guard !isReady else { return }
        let start = Date()
        let set = Self.buildUnion()
        let bitmap = set.bitmapRepresentation
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        install(set, bitmap)
        logBuilt(bytes: bitmap.count, ms: ms)
    }

    /// Warm the union off-main at launch so the first query doesn't pay the
    /// build inline. Best-effort — dropped if a query builds it first.
    func preheat() {
        guard !isReady else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            let set = Self.buildUnion()
            let bitmap = set.bitmapRepresentation
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isReady else { return }
                self.install(set, bitmap)
                self.logBuilt(bytes: bitmap.count, ms: ms)
            }
        }
    }

    /// Install a built union (main only). Does not post `coverageDidChange`
    /// — initial-build consumers block until ready; only `rebuild` notifies.
    private func install(_ set: CharacterSet, _ bitmap: Data) {
        renderableSet = set
        self.bitmap = bitmap
        isReady = true
    }

    private func logBuilt(bytes: Int, ms: Int) {
        Logger.fontCoverage.info(
            "Built font coverage union (\(bytes, privacy: .public) bitmap bytes, \(ms, privacy: .public) ms)"
        )
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
        // CTFontManager.h says to observe the distributed center for user/
        // session-scope changes and the local center for process scope. But on
        // macOS 14, 15 & 26, user-scope installs (Font Book, ~/Library/Fonts)
        // were observed firing only on the local center — matching
        // Apple's own sample (WWDC19 session 227 @12:10), which uses
        // NotificationCenter.default and predates the doc's pre-10.15 wording.
        // Observe both to cover the documented contract and the observed
        // behavior; scheduleRebuild() coalesces duplicates.
        let name = Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)
        NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
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
        DispatchQueue.global(qos: .utility).async {
            let newSet = Self.buildUnion()
            let newBitmap = newSet.bitmapRepresentation
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Compare before install() — it overwrites self.bitmap.
                guard newBitmap != self.bitmap else {
                    Logger.fontCoverage.info("Font change left coverage unchanged; no notification")
                    return
                }
                self.install(newSet, newBitmap)
                Logger.fontCoverage.info("Font coverage changed; posting coverageDidChange")
                NotificationCenter.default.post(name: Self.coverageDidChange, object: nil)
            }
        }
    }
}
