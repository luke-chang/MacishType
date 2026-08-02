import Foundation

/// Locale-keyed associated-mode dictionary. Engines `acquire(for:)` a
/// `Handle`; first acquire loads `AssociatedDictionary.<locale>.txt`, last
/// release unloads.
final class AssociatedDictionary {
    private static let store = RefCountedDictionary<[Character: [String]]>(
        resourceBaseName: "AssociatedDictionary", logger: .associatedDictionary,
        parse: AssociatedDictionary.parse)

    /// True when `AssociatedDictionary.<locale>.txt` is bundled. Lets callers
    /// gate associated-mode UI / behavior without loading the dictionary.
    static func isAvailable(for locale: String) -> Bool {
        store.isAvailable(for: locale)
    }

    /// Acquire a strong reference; the returned `Handle`'s lifetime governs
    /// the refcount.
    static func acquire(for locale: String) -> Handle {
        Handle(inner: store.acquire(for: locale))
    }

    private nonisolated static func parse(_ content: String) -> [Character: [String]] {
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
        private let inner: RefCountedDictionary<[Character: [String]]>.Handle

        fileprivate init(inner: RefCountedDictionary<[Character: [String]]>.Handle) {
            self.inner = inner
        }

        func lookup(_ char: Character) -> [String] {
            inner.value[char] ?? []
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
