import Foundation
import OSLog

/// Locale-keyed associated-phrase dictionary. Engines `acquire(for:)` a
/// `Handle`; first acquire loads `AssociatedPhrases.<locale>.txt`, last
/// release unloads.
final class AssociatedPhrases {
    private struct Slot {
        let instance: AssociatedPhrases
        var count: Int
    }

    // Single source of truth for instance + refcount; main-thread access only.
    private static var slots: [String: Slot] = [:]

    /// Acquire a strong reference; the returned `Handle`'s lifetime governs
    /// the refcount.
    static func acquire(for locale: String) -> Handle {
        Handle(locale: locale)
    }

    private let entries: [Character: [String]]

    private init(locale: String) {
        self.entries = Self.load(locale: locale)
    }

    func lookup(_ char: Character) -> [String] {
        entries[char] ?? []
    }

    private static func incRef(_ locale: String) -> AssociatedPhrases {
        if var slot = slots[locale] {
            slot.count += 1
            slots[locale] = slot
            #if DEBUG
            Logger.associatedPhrases.debug("AssociatedPhrases.\(locale, privacy: .public) acquired (refcount=\(slot.count, privacy: .public))")
            #endif
            return slot.instance
        }
        let new = AssociatedPhrases(locale: locale)
        slots[locale] = Slot(instance: new, count: 1)
        #if DEBUG
        Logger.associatedPhrases.debug("AssociatedPhrases.\(locale, privacy: .public) loaded (\(new.entries.count, privacy: .public) prefixes, refcount=1)")
        #endif
        return new
    }

    private static func decRef(_ locale: String) {
        guard var slot = slots[locale], slot.count > 0 else {
            Logger.associatedPhrases.fault("AssociatedPhrases.\(locale, privacy: .public) released below zero")
            return
        }
        slot.count -= 1
        if slot.count == 0 {
            slots.removeValue(forKey: locale)
            #if DEBUG
            Logger.associatedPhrases.debug("AssociatedPhrases.\(locale, privacy: .public) unloaded")
            #endif
        } else {
            slots[locale] = slot
            #if DEBUG
            Logger.associatedPhrases.debug("AssociatedPhrases.\(locale, privacy: .public) released (refcount=\(slot.count, privacy: .public))")
            #endif
        }
    }

    private static func load(locale: String) -> [Character: [String]] {
        let resource = "AssociatedPhrases.\(locale)"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            Logger.associatedPhrases.fault("\(resource, privacy: .public).txt not found in main bundle (run `make prepare`?)")
            return [:]
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.associatedPhrases.fault("\(resource, privacy: .public).txt exists but could not be read")
            return [:]
        }
        var entries: [Character: [String]] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2,
                  tokens[0].count == 1, let key = tokens[0].first
            else { continue }
            entries[key] = tokens.dropFirst().map(String.init)
        }
        return entries
    }

    /// RAII handle: releasing it (nil-assign or dealloc) decrements the refcount.
    final class Handle {
        let phrases: AssociatedPhrases
        private let locale: String

        fileprivate init(locale: String) {
            self.locale = locale
            self.phrases = AssociatedPhrases.incRef(locale)
        }

        deinit {
            AssociatedPhrases.decRef(locale)
        }
    }
}

/// Reconcile a `Handle?` ivar against current toggle + locale. Engines call
/// this from `load()` and `activate()`; idempotent.
extension InputEngine {
    func reconcileAssociatedPhrases(handle: inout AssociatedPhrases.Handle?) {
        guard showAssociatedWords, let lang = intendedLanguage else {
            handle = nil
            return
        }
        if handle == nil {
            handle = AssociatedPhrases.acquire(for: lang)
        }
    }
}
