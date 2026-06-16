import Foundation
import OSLog

/// Array (行列) data tables and the static lookups they drive. Tables load from
/// the bundle `Array/` subdirectory; per-character frequency and symbol names
/// come from the shared project dictionaries.
final class ArrayDictionary {
    // MARK: - Constants

    static let selectionKeys: [Character] = Array("1234567890")
    static let maxCodeLength = 5
    static let disambiguationKey: Character = "i"
    static let wildcardLimit = 200

    /// Composition key → radical-code label, shown in the marked text (e.g.
    /// `v` → `4⇣`). The data tables ship as plain `code<TAB>char`, so these
    /// labels live here rather than in a cin `%keyname` section.
    static let keyName: [Character: String] = [
        "a": "1-", "b": "5⇣", "c": "3⇣", "d": "3-", "e": "3⇡", "f": "4-",
        "g": "5-", "h": "6-", "i": "8⇡", "j": "7-", "k": "8-", "l": "9-",
        "m": "7⇣", "n": "6⇣", "o": "9⇡", "p": "0⇡", "q": "1⇡", "r": "4⇡",
        "s": "2-", "t": "5⇡", "u": "7⇡", "v": "4⇣", "w": "2⇡", "x": "2⇣",
        "y": "6⇡", "z": "1⇣", ".": "9⇣", "/": "0⇣", ";": "0-", ",": "8⇣",
        "?": "？", "*": "＊",
    ]

    /// Array key character for a W3C `code` (US-QWERTY physical position), so
    /// composition is keyboard-layout-independent. `"KeyA"` → `a`, plus the four
    /// punctuation codes; nil for non-Array keys. The values are exactly
    /// `keyName`'s keys minus `?`/`*` by construction.
    static func arrayKey(forWebCode code: String) -> Character? {
        switch code {
        case "Comma": return ","
        case "Period": return "."
        case "Slash": return "/"
        case "Semicolon": return ";"
        default:
            guard code.count == 4, code.hasPrefix("Key"),
                  let last = code.last, ("A"..."Z").contains(last) else { return nil }
            return Character(last.lowercased())
        }
    }

    /// Names for the symbol groups, shown in the group menu at a symbol prefix.
    static let groupNames: [String: String] = [
        "w0": "注音符號組", "w1": "標點符號組", "w2": "括號符號組", "w3": "一般符號組",
        "w4": "數學符號組", "w5": "方向符號組", "w6": "單位符號組", "w7": "圖表符號組",
        "w8": "順序符號組", "w9": "希臘字母組",
        "hg0": "康熙部首組", "hg1": "標誌符號組", "hg2": "技術符號組",
        "hg8": "表意描述符組", "hg9": "筆畫組",
    ]

    static func hasWildcard(_ code: String) -> Bool {
        code.contains("?") || code.contains("*")
    }

    // MARK: - Tables

    /// `code → candidates`, byte-range backed. Filtered to the current scope at
    /// load and rebuilt on scope/coverage change, so the per-keystroke path —
    /// including the wildcard's whole-table scan — only ever walks displayable
    /// candidates rather than classifying each one per query.
    private var mainTable: ArrayByteTable
    private let phraseTable: ArrayByteTable
    /// Symbol groups (w0…/hg…); small map, filtered to the current scope.
    private var symbolTable: [String: [String]]
    private let shortTable: [String: [(label: Character, value: String)]]
    /// Current scope; `reloadTables` rebuilds the filtered tables when it changes.
    private var scope: InputEngine.CharacterSetScope
    private let frequency: WordFrequencyDictionary.Handle?
    private let symbolNames: SymbolNameDictionary.Handle?

    init(locale: String, scope: InputEngine.CharacterSetScope) {
        frequency = WordFrequencyDictionary.isAvailable(for: locale)
            ? WordFrequencyDictionary.acquire(for: locale) : nil
        symbolNames = SymbolNameDictionary.isAvailable(for: locale)
            ? SymbolNameDictionary.acquire(for: locale) : nil
        self.scope = scope
        mainTable = ArrayByteTable(bytes: Self.filteredBytes("Array30", scope: scope))
        phraseTable = ArrayByteTable(bytes: Self.bundledTableBytes("ArrayPhrase"))
        symbolTable = Self.loadSymbolTable("ArraySymbol", scope: scope)
        shortTable = Self.loadShortCode()
    }

    /// Rebuild the scope-filtered tables (main + symbols). `force` re-filters
    /// even when the scope is unchanged — used when font coverage changed.
    func reloadTables(scope newScope: InputEngine.CharacterSetScope, force: Bool = false) {
        guard force || newScope != scope else { return }
        scope = newScope
        mainTable = ArrayByteTable(bytes: Self.filteredBytes("Array30", scope: newScope))
        symbolTable = Self.loadSymbolTable("ArraySymbol", scope: newScope)
    }

    /// Locate a bundled `Array/<base>.txt`, faulting if it isn't staged.
    private static func bundledTableURL(_ base: String) -> URL? {
        guard let url = Bundle.main.url(
                forResource: base, withExtension: "txt", subdirectory: "Array") else {
            Logger.inputEngine.fault(
                "Array/\(base, privacy: .public).txt not bundled (run `make prepare` and stage Array/Resources)")
            return nil
        }
        return url
    }

    private static func bundledTable(_ base: String) -> String? {
        guard let url = bundledTableURL(base),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content
    }

    /// Read a bundled `Array/<base>.txt` as raw UTF-8 bytes for `ArrayByteTable`.
    private static func bundledTableBytes(_ base: String) -> [UInt8] {
        guard let url = bundledTableURL(base),
              let data = try? Data(contentsOf: url) else { return [] }
        return [UInt8](data)
    }

    /// Iterate the data rows of a `code<TAB>value…` table, skipping comment (`#`)
    /// lines. `fields` is the tab-split row; callers validate arity and content.
    private static func forEachDataRow(in content: String, _ body: ([Substring]) -> Void) {
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            body(raw.split(separator: "\t", omittingEmptySubsequences: false))
        }
    }

    /// Read a bundled `code<TAB>value` table as bytes, keeping only lines whose
    /// value passes `scope` (file/sorted order preserved) so the byte-range table
    /// is pre-filtered. `.full` keeps everything and skips classification.
    private static func filteredBytes(_ base: String, scope: InputEngine.CharacterSetScope) -> [UInt8] {
        guard scope != .full else { return bundledTableBytes(base) }
        guard let content = bundledTable(base) else { return [] }
        var out = ""
        out.reserveCapacity(content.utf8.count)
        forEachDataRow(in: content) { fields in
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return }
            guard scope.accepts(FontCoverage.shared.classify(String(fields[1]))) else { return }
            out += fields[0]; out += "\t"; out += fields[1]; out += "\n"
        }
        return Array(out.utf8)
    }

    /// Load a `code<TAB>value` table (symbol groups) into `code -> [value]`,
    /// keeping only values that pass `scope` (file order preserved).
    private static func loadSymbolTable(_ base: String, scope: InputEngine.CharacterSetScope) -> [String: [String]] {
        guard let content = bundledTable(base) else { return [:] }
        var table: [String: [String]] = [:]
        forEachDataRow(in: content) { fields in
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return }
            guard scope == .full || scope.accepts(FontCoverage.shared.classify(String(fields[1]))) else { return }
            table[String(fields[0]), default: []].append(String(fields[1]))
        }
        return table
    }

    /// Load `code+slotKey<TAB>value` into `code -> [(label, value)]`. The trailing
    /// digit splits off as the label — each candidate's fixed selection key.
    private static func loadShortCode() -> [String: [(label: Character, value: String)]] {
        guard let content = bundledTable("ArrayShortCode") else { return [:] }
        var table: [String: [(label: Character, value: String)]] = [:]
        forEachDataRow(in: content) { fields in
            guard fields.count >= 2, fields[0].count >= 2, !fields[1].isEmpty,
                  let label = fields[0].last else { return }
            let code = String(fields[0].dropLast())
            table[code, default: []].append((label, String(fields[1])))
        }
        return table
    }

    // MARK: - Lookups

    func main(_ code: String) -> [String] { mainTable.lookup(code) }
    func phrase(_ code: String) -> [String] { phraseTable.lookup(code) }
    func symbolGroup(_ code: String) -> [String] { symbolTable[code] ?? [] }
    func hasSymbolGroup(_ code: String) -> Bool { symbolTable[code] != nil }
    func symbolName(_ symbol: String) -> String? { symbolNames?.name(symbol) }

    /// Render a typed code as its radical-code labels for the marked text.
    func radicalReadout(_ code: String) -> String {
        code.map { Self.keyName[$0] ?? String($0) }.joined()
    }

    /// A symbol prefix is a code that a digit extends into a symbol group (e.g.
    /// `w` → `w0`…`w9`).
    func isSymbolPrefix(_ code: String) -> Bool {
        guard !code.isEmpty else { return false }
        return Self.selectionKeys.contains { hasSymbolGroup(code + String($0)) }
    }

    /// A short-code entry's candidates and the fixed selection key each keeps.
    func shortCodeView(_ code: String) -> (candidates: [String], indexLabels: String) {
        let entries = shortTable[code] ?? []
        return (entries.map(\.value), String(entries.map(\.label)))
    }

    /// Wildcard query against the main table. A leading `*` with no other
    /// wildcard matches any code containing those radicals (any order, extra
    /// radicals allowed); otherwise `?` matches one key and `*` one or more.
    /// Results are deduped by character, ranked by frequency (ties keep file
    /// order), capped at `wildcardLimit`, and annotated with the radical readout.
    func wildcardMatches(_ pattern: String) -> [Candidate] {
        // A `*` with no radical matches the whole table — a meaningless flood
        // and a full-table scan; require at least one radical alongside any `*`.
        // A `?`-only pattern (e.g. every single-key code) is bounded and allowed.
        if pattern.contains("*"), !pattern.contains(where: { $0 != "*" && $0 != "?" }) {
            return []
        }
        let patternBytes = Array(pattern.utf8)
        let matches: (UnsafeBufferPointer<UInt8>, Range<Int>) -> Bool
        if patternBytes.first == star && !Self.hasWildcard(String(pattern.dropFirst())) {
            let required = Array(patternBytes.dropFirst())
            matches = { buffer, range in
                // Plain loops, not `allSatisfy`/`contains(where:)`: this runs per
                // code over the whole table, and the closure forms don't inline
                // under `-Onone` (each element pays a closure call).
                for req in required {
                    var found = false
                    var i = range.lowerBound
                    while i < range.upperBound { if buffer[i] == req { found = true; break }; i += 1 }
                    if !found { return false }
                }
                return true
            }
        } else {
            matches = { buffer, range in Self.positionalMatch(patternBytes, buffer, range) }
        }

        // Codes are visited in code order, so equal-frequency ties resolve
        // deterministically by code (where each char first appears).
        var seen = Set<String>()
        var found: [(char: String, code: String, order: Int, freq: Int)] = []
        mainTable.forEachMatchingCode(where: matches) { code, values in
            for char in values where seen.insert(char).inserted {
                found.append((char, code, found.count, frequency?.frequency(char) ?? 0))
            }
        }
        // Rank by frequency desc, ties keep code order. Frequency is looked up
        // once per candidate above, not inside the comparator.
        found.sort { $0.freq != $1.freq ? $0.freq > $1.freq : $0.order < $1.order }
        return found.prefix(Self.wildcardLimit).map {
            Candidate($0.char, annotation: radicalReadout($0.code))
        }
    }

    /// Positional wildcard match over a code's bytes: `?` = one key, `*` = one
    /// or more keys. Codes and patterns are ASCII, so byte comparison suffices.
    private static func positionalMatch(
        _ pattern: [UInt8], _ buffer: UnsafeBufferPointer<UInt8>, _ range: Range<Int>
    ) -> Bool {
        func match(_ pi: Int, _ ci: Int) -> Bool {
            if pi == pattern.count { return ci == range.upperBound }
            switch pattern[pi] {
            case star:
                guard ci < range.upperBound else { return false }  // one or more
                var next = ci + 1
                while next <= range.upperBound { if match(pi + 1, next) { return true }; next += 1 }
                return false
            case question:
                return ci < range.upperBound && match(pi + 1, ci + 1)
            case let expected:
                return ci < range.upperBound && buffer[ci] == expected && match(pi + 1, ci + 1)
            }
        }
        return match(0, range.lowerBound)
    }
}

// MARK: - ASCII wildcard byte constants

nonisolated private let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
