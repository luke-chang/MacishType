import Foundation

/// Symbol-to-name table shared across the project (e.g. "，" → "逗號"). Engines
/// `acquire(for:)` a `Handle`; first acquire loads `SymbolNames.<locale>.txt`,
/// last release unloads.
final class SymbolNameDictionary {
    private static let store = RefCountedDictionary<[String: String]>(
        resourceBaseName: "SymbolNames", logger: .symbolName,
        parse: SymbolNameDictionary.parse)

    static func isAvailable(for locale: String) -> Bool {
        store.isAvailable(for: locale)
    }

    static func acquire(for locale: String) -> Handle {
        Handle(inner: store.acquire(for: locale))
    }

    private nonisolated static func parse(_ content: String) -> [String: String] {
        var entries: [String: String] = [:]
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // A leading "# " marks a header comment, but "#" itself is a valid
            // symbol key whose data row is "#<TAB>name" — keep those.
            if raw.hasPrefix("#"), !raw.hasPrefix("#\t") { continue }
            guard let tab = raw.firstIndex(of: "\t") else { continue }
            let symbol = String(raw[..<tab])
            guard !symbol.isEmpty else { continue }
            entries[symbol] = String(raw[raw.index(after: tab)...])
        }
        return entries
    }

    final class Handle {
        private let inner: RefCountedDictionary<[String: String]>.Handle

        fileprivate init(inner: RefCountedDictionary<[String: String]>.Handle) {
            self.inner = inner
        }

        func name(_ symbol: String) -> String? {
            inner.value[symbol]
        }

        /// The whole table, for callers that marshal it elsewhere in one shot.
        var entries: [String: String] { inner.value }
    }
}
