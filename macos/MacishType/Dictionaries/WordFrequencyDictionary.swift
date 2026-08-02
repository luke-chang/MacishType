import Foundation

/// Per-character frequency table shared across the project. Engines
/// `acquire(for:)` a `Handle`; first acquire loads `WordFrequency.<locale>.txt`,
/// last release unloads. Higher counts mean more frequent characters.
final class WordFrequencyDictionary {
    private static let store = RefCountedDictionary<[String: Int]>(
        resourceBaseName: "WordFrequency", logger: .wordFrequency,
        parse: WordFrequencyDictionary.parse)

    static func isAvailable(for locale: String) -> Bool {
        store.isAvailable(for: locale)
    }

    static func acquire(for locale: String) -> Handle {
        Handle(inner: store.acquire(for: locale))
    }

    private nonisolated static func parse(_ content: String) -> [String: Int] {
        // Lines are `char<TAB>count`; `#` starts a comment.
        var entries: [String: Int] = [:]
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            guard let tab = raw.firstIndex(of: "\t") else { continue }
            let char = String(raw[..<tab])
            guard !char.isEmpty, let count = Int(raw[raw.index(after: tab)...]) else { continue }
            entries[char] = count
        }
        return entries
    }

    final class Handle {
        private let inner: RefCountedDictionary<[String: Int]>.Handle

        fileprivate init(inner: RefCountedDictionary<[String: Int]>.Handle) {
            self.inner = inner
        }

        /// Frequency count for `char`, or 0 when absent.
        func frequency(_ char: String) -> Int {
            inner.value[char] ?? 0
        }

        /// The whole table, for callers that marshal it elsewhere in one shot.
        var entries: [String: Int] { inner.value }
    }
}
