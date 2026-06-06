import Foundation
import OSLog

/// Locale-keyed associated-mode dictionary. Engines `acquire(for:)` a
/// `Handle`; first acquire loads `AssociatedDictionary.<locale>.txt`, last
/// release unloads.
final class AssociatedDictionary {
    private struct Slot {
        let instance: AssociatedDictionary
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

    private static func incRef(_ locale: String) -> AssociatedDictionary {
        if var slot = slots[locale] {
            slot.count += 1
            slots[locale] = slot
            #if DEBUG
            Logger.associatedDictionary.debug("AssociatedDictionary.\(locale, privacy: .public) acquired (refcount=\(slot.count, privacy: .public))")
            #endif
            return slot.instance
        }
        let new = AssociatedDictionary(locale: locale)
        slots[locale] = Slot(instance: new, count: 1)
        #if DEBUG
        Logger.associatedDictionary.debug("AssociatedDictionary.\(locale, privacy: .public) loaded (\(new.entries.count, privacy: .public) prefixes, refcount=1)")
        #endif
        return new
    }

    private static func decRef(_ locale: String) {
        guard var slot = slots[locale], slot.count > 0 else {
            Logger.associatedDictionary.fault("AssociatedDictionary.\(locale, privacy: .public) released below zero")
            return
        }
        slot.count -= 1
        if slot.count == 0 {
            slots.removeValue(forKey: locale)
            #if DEBUG
            Logger.associatedDictionary.debug("AssociatedDictionary.\(locale, privacy: .public) unloaded")
            #endif
        } else {
            slots[locale] = slot
            #if DEBUG
            Logger.associatedDictionary.debug("AssociatedDictionary.\(locale, privacy: .public) released (refcount=\(slot.count, privacy: .public))")
            #endif
        }
    }

    private static func resourceName(for locale: String) -> String {
        "AssociatedDictionary.\(locale)"
    }

    // Bundle resource presence by locale; lookups are cheap but `isAvailable`
    // runs on every Settings render, so cache the one-time probe. Entries
    // never invalidate — bundled dictionaries don't change at runtime.
    private static var availabilityCache: [String: Bool] = [:]

    /// True when `AssociatedDictionary.<locale>.txt` is bundled. Lets callers
    /// gate associated-mode UI / behavior without loading the dictionary.
    static func isAvailable(for locale: String) -> Bool {
        if let cached = availabilityCache[locale] { return cached }
        let present = Bundle.main.url(
            forResource: resourceName(for: locale), withExtension: "txt") != nil
        availabilityCache[locale] = present
        return present
    }

    private static func load(locale: String) -> [Character: [String]] {
        let resource = resourceName(for: locale)
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            Logger.associatedDictionary.fault("\(resource, privacy: .public).txt not found in main bundle (run `make prepare`?)")
            return [:]
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.associatedDictionary.fault("\(resource, privacy: .public).txt exists but could not be read")
            return [:]
        }
        var entries: [Character: [String]] = [:]
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            // Key and phrase list are TAB-separated; phrases within the list
            // are space-separated.
            guard let tab = raw.firstIndex(of: "\t") else { continue }
            let key = raw[..<tab]
            guard key.count == 1, let keyChar = key.first else { continue }
            let phrases = raw[raw.index(after: tab)...]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard !phrases.isEmpty else { continue }
            entries[keyChar] = phrases
        }
        return entries
    }

    /// RAII handle: releasing it (nil-assign or dealloc) decrements the refcount.
    final class Handle {
        private let instance: AssociatedDictionary
        private let locale: String

        fileprivate init(locale: String) {
            self.locale = locale
            self.instance = AssociatedDictionary.incRef(locale)
        }

        deinit {
            AssociatedDictionary.decRef(locale)
        }

        func lookup(_ char: Character) -> [String] {
            instance.entries[char] ?? []
        }
    }
}

/// Reconcile a `Handle?` ivar against current toggle + locale. Engines call
/// this from `load()` and `activate()`; idempotent.
extension InputEngine {
    func reconcileAssociatedDictionary(handle: inout AssociatedDictionary.Handle?) {
        guard enableAssociatedMode, let lang = intendedLanguage,
              AssociatedDictionary.isAvailable(for: lang) else {
            handle = nil
            return
        }
        if handle == nil {
            handle = AssociatedDictionary.acquire(for: lang)
        }
    }
}
