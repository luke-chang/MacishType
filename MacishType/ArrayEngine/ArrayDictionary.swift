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

    /// Keys that build a composition: every `keyName` key except the wildcards.
    static let compositionKeys: Set<Character> =
        Set(ArrayDictionary.keyName.keys).subtracting(["?", "*"])

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

    private var mainTable: [String: [String]] = [:]
    private var mainCodesInOrder: [String] = []       // file order, for wildcard ranking ties
    private var symbolTable: [String: [String]] = [:] // symbol groups (w0…/hg…)
    private var shortTable: [String: [(label: Character, value: String)]] = [:]
    private var phraseTable: [String: [String]] = [:]
    private var includesRare: Bool
    private let frequency: WordFrequencyDictionary.Handle?
    private let symbolNames: SymbolNameDictionary.Handle?

    init(locale: String, includeRare: Bool) {
        frequency = WordFrequencyDictionary.isAvailable(for: locale)
            ? WordFrequencyDictionary.acquire(for: locale) : nil
        symbolNames = SymbolNameDictionary.isAvailable(for: locale)
            ? SymbolNameDictionary.acquire(for: locale) : nil
        includesRare = includeRare
        (mainTable, mainCodesInOrder) = Self.loadTable("Array30", includeRare: includeRare, trackOrder: true)
        symbolTable = Self.loadTable("ArraySymbol", includeRare: includeRare).table
        shortTable = Self.loadShortCode()
        phraseTable = Self.loadTable("ArrayPhrase", includeRare: true).table
    }

    /// Reload the rare-filtered tables (main and symbols) when the setting toggles.
    func reloadRareTables(includeRare: Bool) {
        guard includeRare != includesRare else { return }
        includesRare = includeRare
        (mainTable, mainCodesInOrder) = Self.loadTable("Array30", includeRare: includeRare, trackOrder: true)
        symbolTable = Self.loadTable("ArraySymbol", includeRare: includeRare).table
    }

    /// Read a bundled `Array/<base>.txt`, faulting if it isn't staged.
    private static func bundledTable(_ base: String) -> String? {
        guard let url = Bundle.main.url(
                forResource: base, withExtension: "txt", subdirectory: "Array"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.inputEngine.fault(
                "Array/\(base, privacy: .public).txt not bundled (run `make prepare` and stage Array/Resources)")
            return nil
        }
        return content
    }

    /// Load a `code<TAB>value[<TAB>*]` table from the bundle `Array/`
    /// subdirectory into `code -> [value, ...]` (appended in file order). A
    /// non-empty third column marks a rare value (no bundled-font glyph),
    /// skipped unless `includeRare`.
    /// `order` (first-appearance code order, for wildcard ranking) is built only
    /// when `trackOrder` is set; other tables skip that work.
    private static func loadTable(
        _ base: String, includeRare: Bool, trackOrder: Bool = false
    ) -> (table: [String: [String]], order: [String]) {
        guard let content = bundledTable(base) else { return ([:], []) }
        var table: [String: [String]] = [:]
        var order: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            if fields.count >= 3, !fields[2].isEmpty, !includeRare { continue }
            let code = String(fields[0])
            if trackOrder && table[code] == nil { order.append(code) }
            table[code, default: []].append(String(fields[1]))
        }
        return (table, order)
    }

    /// Load `code+slotKey<TAB>value` into `code -> [(label, value)]`. The trailing
    /// digit splits off as the label — each candidate's fixed selection key.
    private static func loadShortCode() -> [String: [(label: Character, value: String)]] {
        guard let content = bundledTable("ArrayShortCode") else { return [:] }
        var table: [String: [(label: Character, value: String)]] = [:]
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0].count >= 2, !fields[1].isEmpty,
                  let label = fields[0].last else { continue }
            let code = String(fields[0].dropLast())
            table[code, default: []].append((label, String(fields[1])))
        }
        return table
    }

    // MARK: - Lookups

    func main(_ code: String) -> [String] { mainTable[code] ?? [] }
    func phrase(_ code: String) -> [String] { phraseTable[code] ?? [] }
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
    /// wildcard matches the radicals in any order; otherwise `?` matches one
    /// key and `*` one or more. Results are deduped by character, ranked by
    /// frequency (ties keep file order), capped at `wildcardLimit`, and
    /// annotated with the matched code's radical readout.
    func wildcardMatches(_ pattern: String) -> [Candidate] {
        let matches: (String) -> Bool
        if pattern.hasPrefix("*") && !Self.hasWildcard(String(pattern.dropFirst())) {
            let target = String(pattern.dropFirst().sorted())
            matches = { String($0.sorted()) == target }
        } else {
            let pat = Array(pattern)
            matches = { Self.positionalMatch(pat, Array($0)) }
        }

        var seen = Set<String>()
        var found: [(char: String, code: String, order: Int, freq: Int)] = []
        for code in mainCodesInOrder {
            guard matches(code) else { continue }
            for char in mainTable[code] ?? [] where seen.insert(char).inserted {
                found.append((char, code, found.count, frequency?.frequency(char) ?? 0))
            }
        }
        // Rank by frequency desc, ties keep file order. Frequency is looked up
        // once per candidate above, not inside the comparator.
        found.sort { $0.freq != $1.freq ? $0.freq > $1.freq : $0.order < $1.order }
        return found.prefix(Self.wildcardLimit).map {
            Candidate($0.char, annotation: radicalReadout($0.code))
        }
    }

    /// Positional wildcard match: `?` = one key, `*` = one or more keys.
    private static func positionalMatch(_ pattern: [Character], _ code: [Character]) -> Bool {
        func match(_ pi: Int, _ ci: Int) -> Bool {
            if pi == pattern.count { return ci == code.count }
            switch pattern[pi] {
            case "*":
                guard ci < code.count else { return false }  // one or more
                return (ci + 1...code.count).contains { match(pi + 1, $0) }
            case "?":
                return ci < code.count && match(pi + 1, ci + 1)
            case let expected:
                return ci < code.count && code[ci] == expected && match(pi + 1, ci + 1)
            }
        }
        return match(0, 0)
    }
}
