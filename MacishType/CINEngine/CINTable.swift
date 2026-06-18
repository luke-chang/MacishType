import Foundation

/// Parsed CIN table: keyname (display roots), chardef (code → candidates),
/// and the directives a generic table-based engine needs (selkey, endkey,
/// keep_key_case). Mirrors the cin format documented by OpenVanilla's
/// OVCINDataTable BNF and gcin/jscin; only the directives actually used by
/// real-world tables are honored, everything else is ignored.
///
/// Storage is a single immutable UTF-8 byte blob (the raw file) plus a sorted
/// array of byte-range entries — codes and candidates are never materialized
/// as `String` at load time, only on demand at query time. This keeps loading
/// and memory flat even for very large tables (hundreds of thousands of
/// chardef lines): one buffer, one entry array, no per-line allocation.
///
/// `nonisolated` (the project defaults to main-actor isolation): this is
/// immutable parsed data with no shared mutable state, so it can be built and
/// queried from any context — e.g. the nonisolated file-picker validator.
nonisolated final class CINTable: Sendable {
    /// Display names (informational; the input-menu name comes from Info.plist).
    /// `ename` is resolved from the possibly multi-language inline `%ename`
    /// value (`Name:en;名:zh;…`) for the app's locale.
    let ename: String?
    let cname: String?

    /// Selection keys. Defaults to "123456789" when %selkey is absent,
    /// matching the gen_inp fallback. Not necessarily digits (e.g. dayi3).
    let selkey: String

    /// Keys that, once appended, immediately compose (act like Space).
    let endkey: Set<Character>

    /// When true (the bare %keep_key_case directive is present), codes keep
    /// upper/lower distinction; otherwise input is lowercased.
    let keepKeyCase: Bool

    /// Longest valid chardef code length — the input cap. Derived from the
    /// table (cin has no max-length directive), measured after noise lines
    /// are skipped.
    let maxCodeLength: Int

    /// True when live preview is unambiguous: no complete code `c` exists
    /// such that `c + selkeyChar` is a prefix of some code. When true, a
    /// selkey press at a candidate-bearing code can only ever mean
    /// selection, never extension.
    let isPreviewable: Bool

    /// Candidate-window selection labels (the selkey, ASCII-validated and
    /// capped at the max page size) and the matching page size — derived once.
    let indexLabels: String
    let pageSize: Int

    /// keyname mapping — display only. May not enumerate every input key
    /// (some tables use code chars absent from keyname), so it is never used
    /// to decide what counts as an input key; `codeKeys` does that.
    private let keyToRoot: [Character: String]

    /// Distinct (normalized) characters used in any chardef code — the table's
    /// input alphabet.
    private let codeKeys: Set<Character>

    /// One chardef line: code and candidate as byte ranges into `buf`.
    /// `Int32` is ample — cin files never approach 2 GB — and halves the
    /// entry footprint versus `Int`.
    private struct Entry: Sendable {
        var codeStart: Int32
        var codeEnd: Int32
        var valStart: Int32
        var valEnd: Int32
    }

    /// The raw file bytes (UTF-8). Codes are lowercased in place during the
    /// scan when `keepKeyCase` is false; everything else is untouched. All
    /// entry ranges point into this buffer.
    private let buf: [UInt8]

    /// chardef entries sorted by code bytes (UTF-8 lexicographic), with
    /// `codeStart` breaking ties so entries for the same code keep file order
    /// (stable) — `codeStart` strictly increases with append order, so it
    /// needs no extra field. Duplicate codes are therefore adjacent, and one
    /// sorted structure answers both exact lookups (binary search to the first
    /// match, then scan the equal run) and prefix queries (lower bound).
    private let entries: [Entry]

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var buf = [UInt8](data)

        enum Section { case none, keyname, chardef }
        var section = Section.none

        var ename: String?
        var cname: String?
        var selkeyValue: String?
        var endkeyChars = Set<Character>()
        var keepCase = false
        var keyToRoot: [Character: String] = [:]
        var entries: [Entry] = []
        entries.reserveCapacity(buf.count / 8)
        var maxLength = 0
        var codeKeyBytes = Set<UInt8>()

        buf.withUnsafeMutableBufferPointer { p in
            let n = p.count
            var i = 0
            while i < n {
                // Line bounds [lineStart, lineEnd), CR stripped, LF consumed.
                let lineStart = i
                while i < n && p[i] != newline { i += 1 }
                var lineEnd = i
                if lineEnd > lineStart && p[lineEnd - 1] == carriage { lineEnd -= 1 }
                if i < n { i += 1 }

                // Skip leading whitespace; ignore blank and comment lines.
                var cs = lineStart
                while cs < lineEnd && isWhitespace(p[cs]) { cs += 1 }
                if cs >= lineEnd { continue }
                let firstByte = p[cs]
                if firstByte == hash { continue }

                // Section boundaries are whitespace-tokenized: some tables write
                // "%keyname  begin" with two spaces, so a literal " begin" match
                // would miss them. Directives are rare, so decoding the line to a
                // String here costs nothing; the chardef hot path stays byte-only.
                if firstByte == percent {
                    let line = String(decoding: p[cs ..< lineEnd], as: UTF8.self)
                    let parts = line.split(maxSplits: 1, whereSeparator: isWhitespaceChar)
                    let directive = String(parts[0])
                    let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    let firstArg = value.split(whereSeparator: isWhitespaceChar).first.map(String.init) ?? ""
                    switch directive {
                    case "%keyname":
                        section = (firstArg == "begin") ? .keyname : .none
                    case "%chardef":
                        section = (firstArg == "begin") ? .chardef : .none
                    case "%ename" where section == .none:
                        ename = value.isEmpty ? nil : value
                    case "%cname" where section == .none:
                        cname = value.isEmpty ? nil : value
                    case "%selkey" where section == .none:
                        selkeyValue = value.isEmpty ? nil : value
                    case "%endkey" where section == .none:
                        endkeyChars.formUnion(value)
                    case "%keep_key_case" where section == .none:
                        keepCase = true
                    default:
                        // %space_style, %dupsel, %gen_inp, and any unknown
                        // directive (incl. chardef-block noise like %O / %0.) are
                        // ignored. Inside a block this is the skip branch that
                        // keeps bogus "codes" out of the table.
                        break
                    }
                    continue
                }

                switch section {
                case .keyname:
                    let line = String(decoding: p[cs ..< lineEnd], as: UTF8.self)
                    let toks = line.split(whereSeparator: isWhitespaceChar)
                    guard toks.count >= 2, toks[0].count == 1, let keyChar = toks[0].first else { continue }
                    let normalized = keepCase ? keyChar : Character(keyChar.lowercased())
                    keyToRoot[normalized] = String(toks[1])
                case .chardef:
                    // Code = first whitespace-delimited token.
                    var tokEnd = cs
                    while tokEnd < lineEnd && !isWhitespace(p[tokEnd]) { tokEnd += 1 }
                    guard tokEnd > cs, tokEnd < lineEnd else { continue }
                    // Value = rest of line after the whole whitespace run, with
                    // trailing ASCII whitespace trimmed. Only ASCII whitespace is
                    // trimmed: a full-width space (U+3000) can be a real candidate.
                    var valStart = tokEnd
                    while valStart < lineEnd && isWhitespace(p[valStart]) { valStart += 1 }
                    var valEnd = lineEnd
                    while valEnd > valStart && isWhitespace(p[valEnd - 1]) { valEnd -= 1 }
                    guard valStart < valEnd else { continue }
                    // Defensive: strip a leading representative-code marker.
                    if p[valStart] == star { valStart += 1 }
                    guard valStart < valEnd else { continue }
                    // Lowercase ASCII code bytes in place (when not keepKeyCase).
                    if !keepCase {
                        var k = cs
                        while k < tokEnd {
                            let byte = p[k]
                            if byte >= upperA && byte <= upperZ { p[k] = byte + 32 }
                            k += 1
                        }
                    }
                    var keyIndex = cs
                    while keyIndex < tokEnd { codeKeyBytes.insert(p[keyIndex]); keyIndex += 1 }
                    entries.append(Entry(codeStart: Int32(cs), codeEnd: Int32(tokEnd),
                                         valStart: Int32(valStart), valEnd: Int32(valEnd)))
                    let len = tokEnd - cs
                    if len > maxLength { maxLength = len }
                case .none:
                    break
                }
            }

            // Sort by code bytes; codeStart breaks ties to preserve file order.
            entries.sort { lhs, rhs in
                let lc = Int(lhs.codeEnd - lhs.codeStart), rc = Int(rhs.codeEnd - rhs.codeStart)
                let m = min(lc, rc)
                var k = 0
                while k < m {
                    let x = p[Int(lhs.codeStart) + k], y = p[Int(rhs.codeStart) + k]
                    if x != y { return x < y }
                    k += 1
                }
                if lc != rc { return lc < rc }
                return lhs.codeStart < rhs.codeStart
            }
        }

        guard !entries.isEmpty else { return nil }

        let resolvedSelkey = selkeyValue?.isEmpty == false ? selkeyValue! : "123456789"
        let maxPage = CandidateWindowConfiguration.validPageSizeRange.upperBound
        let labels = String(resolvedSelkey.filter(\.isValidIndexLabel).prefix(maxPage))
        let validLabels = labels.isEmpty ? "123456789" : labels

        self.ename = Self.resolveName(ename)
        self.cname = cname
        self.selkey = resolvedSelkey
        self.endkey = endkeyChars
        self.keepKeyCase = keepCase
        self.keyToRoot = keyToRoot
        self.codeKeys = Set(codeKeyBytes.map { Character(Unicode.Scalar($0)) })
        self.buf = buf
        self.entries = entries
        self.maxCodeLength = max(maxLength, 1)
        self.indexLabels = validLabels
        self.pageSize = validLabels.count
        self.isPreviewable = Self.computePreviewable(
            buf: buf, entries: entries, selkey: resolvedSelkey, keepCase: keepCase)
    }

    // MARK: - Queries

    func normalize(_ code: String) -> String {
        keepKeyCase ? code : code.lowercased()
    }

    func lookup(_ code: String) -> [String] {
        let key = Array(normalize(code).utf8)
        return buf.withUnsafeBufferPointer { p in
            let lb = Self.lowerBound(p, entries, key)
            guard lb < entries.count, Self.isExact(p, entries[lb], key) else { return [] }
            var result = [String]()
            var idx = lb
            while idx < entries.count {
                let entry = entries[idx]
                guard Self.isExact(p, entry, key) else { break }
                result.append(String(decoding: p[Int(entry.valStart) ..< Int(entry.valEnd)], as: UTF8.self))
                idx += 1
            }
            return result
        }
    }

    func hasCandidates(_ code: String) -> Bool {
        let key = Array(normalize(code).utf8)
        return buf.withUnsafeBufferPointer { p in
            let lb = Self.lowerBound(p, entries, key)
            return lb < entries.count && Self.isExact(p, entries[lb], key)
        }
    }

    /// Concatenated display roots for the composing buffer; falls back to the
    /// raw character when a key has no keyname entry.
    func rootDisplay(_ code: String) -> String {
        var result = ""
        for char in normalize(code) {
            result += keyToRoot[char] ?? String(char)
        }
        return result
    }

    func isEndKey(_ char: Character) -> Bool {
        endkey.contains(char)
    }

    /// Whether `char` is in the table's input alphabet (may compose, prefix or not).
    func isCodeKey(_ char: Character) -> Bool {
        codeKeys.contains(keepKeyCase ? char : Character(char.lowercased()))
    }

    /// Enumerate each unique code with its candidates in file order. Lets an
    /// engine build a derived (e.g. coverage-filtered) candidate table without
    /// holding a second materialized copy of the whole table — values are
    /// decoded only as the closure consumes them.
    func enumerateCandidates(_ body: (_ code: String, _ values: [String]) -> Void) {
        buf.withUnsafeBufferPointer { p in
            var i = 0
            while i < entries.count {
                let base = entries[i]
                let code = String(decoding: p[Int(base.codeStart) ..< Int(base.codeEnd)], as: UTF8.self)
                var values = [String]()
                var j = i
                while j < entries.count, Self.sameCode(p, entries[j], base) {
                    let entry = entries[j]
                    values.append(String(decoding: p[Int(entry.valStart) ..< Int(entry.valEnd)], as: UTF8.self))
                    j += 1
                }
                body(code, values)
                i = j
            }
        }
    }

    // MARK: - Byte-range search helpers
    //
    // Static so the query methods and the static `computePreviewable` (which
    // runs before `self` exists) share one binary search and one comparison
    // rather than each rolling its own.

    /// First entry whose code is >= `key` (lower bound over the sorted codes).
    private static func lowerBound(_ p: UnsafeBufferPointer<UInt8>, _ entries: [Entry], _ key: [UInt8]) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compareCode(p, entries[mid], key) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Lexicographic comparison of an entry's code bytes against `key`.
    private static func compareCode(_ p: UnsafeBufferPointer<UInt8>, _ entry: Entry, _ key: [UInt8]) -> Int {
        let codeLen = Int(entry.codeEnd - entry.codeStart), keyLen = key.count
        let m = min(codeLen, keyLen)
        let start = Int(entry.codeStart)
        var k = 0
        while k < m {
            let x = p[start + k], y = key[k]
            if x != y { return x < y ? -1 : 1 }
            k += 1
        }
        return codeLen == keyLen ? 0 : (codeLen < keyLen ? -1 : 1)
    }

    private static func hasPrefix(_ p: UnsafeBufferPointer<UInt8>, _ entry: Entry, _ key: [UInt8]) -> Bool {
        guard Int(entry.codeEnd - entry.codeStart) >= key.count else { return false }
        let start = Int(entry.codeStart)
        for k in 0 ..< key.count where p[start + k] != key[k] { return false }
        return true
    }

    private static func isExact(_ p: UnsafeBufferPointer<UInt8>, _ entry: Entry, _ key: [UInt8]) -> Bool {
        compareCode(p, entry, key) == 0
    }

    private static func sameCode(_ p: UnsafeBufferPointer<UInt8>, _ lhs: Entry, _ rhs: Entry) -> Bool {
        let len = Int(lhs.codeEnd - lhs.codeStart)
        guard Int(rhs.codeEnd - rhs.codeStart) == len else { return false }
        let ls = Int(lhs.codeStart), rs = Int(rhs.codeStart)
        for k in 0 ..< len where p[ls + k] != p[rs + k] { return false }
        return true
    }

    // MARK: - Name resolution

    /// Resolve a name that may be the inline multi-language form
    /// `Name:en;名:zh_CN;名:zh;` to a single name for the app's locale
    /// (Traditional Chinese first, then English, then whatever leads). A plain
    /// name (no `name:lang` entries) is returned unchanged.
    nonisolated private static func resolveName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let entries: [(lang: String, name: String)] = raw.split(separator: ";").compactMap { entry in
            guard let colon = entry.lastIndex(of: ":") else { return nil }
            let name = entry[..<colon].trimmingCharacters(in: .whitespaces)
            let lang = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty || lang.isEmpty ? nil : (lang, name)
        }
        guard !entries.isEmpty else { return raw }
        let preferred = ["zh-hant", "zh_hant", "zh-tw", "zh_tw", "zh", "en"]
        for tag in preferred {
            if let match = entries.first(where: { $0.lang == tag }) { return match.name }
        }
        return entries.first?.name
    }

    // MARK: - Preview safety

    /// A table is preview-safe unless some complete code `c` can be extended
    /// by a selkey char into a prefix of another code — that's the only way a
    /// selkey press could be ambiguous (extend vs select) while candidates
    /// show. Pruned: only codes that are a proper prefix of the next distinct
    /// code can possibly qualify.
    private static func computePreviewable(
        buf: [UInt8], entries: [Entry], selkey: String, keepCase: Bool
    ) -> Bool {
        guard !entries.isEmpty else { return true }
        let selSeqs = (keepCase ? selkey : selkey.lowercased()).map { Array(String($0).utf8) }
        guard !selSeqs.isEmpty else { return true }

        return buf.withUnsafeBufferPointer { p in
            // Does some code start with `probe`? Same binary search the queries use.
            func prefixExists(_ probe: [UInt8]) -> Bool {
                guard !probe.isEmpty else { return false }
                let lb = lowerBound(p, entries, probe)
                return lb < entries.count && hasPrefix(p, entries[lb], probe)
            }

            var i = 0
            while i < entries.count {
                let cur = entries[i]
                let curLen = Int(cur.codeEnd - cur.codeStart)
                let curStart = Int(cur.codeStart)
                // Advance to the next distinct code.
                var j = i + 1
                while j < entries.count && sameCode(p, entries[j], cur) { j += 1 }
                if j < entries.count {
                    let next = entries[j]
                    // Cheap prune: `cur` matters only if the next distinct code
                    // extends it (i.e. `cur` is a proper prefix of `next`).
                    if Int(next.codeEnd - next.codeStart) >= curLen {
                        let nextStart = Int(next.codeStart)
                        var isPrefix = true
                        for k in 0 ..< curLen where p[nextStart + k] != p[curStart + k] { isPrefix = false; break }
                        if isPrefix {
                            var probe = [UInt8](); probe.reserveCapacity(curLen + 4)
                            for k in 0 ..< curLen { probe.append(p[curStart + k]) }
                            let base = probe.count
                            for sel in selSeqs {
                                probe.replaceSubrange(base..., with: sel)
                                if prefixExists(probe) { return false }
                            }
                        }
                    }
                }
                i = j
            }
            return true
        }
    }
}

// MARK: - ASCII byte predicates

nonisolated private let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
nonisolated private let newline = UInt8(ascii: "\n"), carriage = UInt8(ascii: "\r")
nonisolated private let hash = UInt8(ascii: "#"), percent = UInt8(ascii: "%"), star = UInt8(ascii: "*")
nonisolated private let upperA = UInt8(ascii: "A"), upperZ = UInt8(ascii: "Z")

@inline(__always) nonisolated private func isWhitespace(_ byte: UInt8) -> Bool { byte == space || byte == tab }
@inline(__always) nonisolated private func isWhitespaceChar(_ char: Character) -> Bool { char == " " || char == "\t" }
