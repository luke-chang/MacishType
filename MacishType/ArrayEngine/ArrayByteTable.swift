import Foundation

/// Byte-range storage for a `code<TAB>value` plain-text table. The whole file
/// is kept as one immutable UTF-8 blob; each data line is an `Entry` of byte
/// ranges into it, so codes and values are materialized as `String` only on
/// demand at query time. This keeps load time and memory flat for large tables.
///
/// `entries` are code-sorted (UTF-8 byte order, stable within a code) by the
/// build step (ExtractCodeTable), which lookup and enumeration rely on.
/// Sorted storage answers exact lookups by binary search and unique-code
/// enumeration by scanning adjacent equal-code runs. Codes are stored verbatim;
/// Array codes are lowercase by construction, so no case folding happens here.
nonisolated struct ArrayByteTable: Sendable {
    private struct Entry: Sendable {
        var codeStart: Int32
        var codeEnd: Int32
        var valStart: Int32
        var valEnd: Int32
    }

    private let buf: [UInt8]
    private let entries: [Entry]

    init(bytes: [UInt8]) {
        buf = bytes
        var entries: [Entry] = []
        entries.reserveCapacity(bytes.count / 8)

        buf.withUnsafeBufferPointer { p in
            let n = p.count
            var i = 0
            while i < n {
                let lineStart = i
                while i < n && p[i] != newline { i += 1 }
                var lineEnd = i
                if lineEnd > lineStart && p[lineEnd - 1] == carriage { lineEnd -= 1 }
                if i < n { i += 1 }

                if lineStart >= lineEnd || p[lineStart] == hash { continue }

                // code = before the first tab; value = between the first and
                // second tab (any further tabs are ignored).
                var firstTab = lineStart
                while firstTab < lineEnd && p[firstTab] != tab { firstTab += 1 }
                guard firstTab < lineEnd else { continue }
                var secondTab = firstTab + 1
                while secondTab < lineEnd && p[secondTab] != tab { secondTab += 1 }

                let codeStart = lineStart, codeEnd = firstTab
                let valStart = firstTab + 1, valEnd = secondTab
                guard codeEnd > codeStart, valEnd > valStart else { continue }
                entries.append(Entry(codeStart: Int32(codeStart), codeEnd: Int32(codeEnd),
                                     valStart: Int32(valStart), valEnd: Int32(valEnd)))
            }
        }

        self.entries = entries
    }

    // MARK: - Exact lookup

    /// Candidate values for `code`, in file order, or `[]` if absent.
    func lookup(_ code: String) -> [String] {
        let key = Array(code.utf8)
        return buf.withUnsafeBufferPointer { p in
            var index = lowerBound(p, key)
            var result = [String]()
            while index < entries.count, isExact(p, entries[index], key) {
                let entry = entries[index]
                result.append(String(decoding: p[Int(entry.valStart) ..< Int(entry.valEnd)], as: UTF8.self))
                index += 1
            }
            return result
        }
    }

    // MARK: - Wildcard enumeration

    /// Call `body` with each unique code (and its candidate values, file order)
    /// whose bytes satisfy `matches`. Matching runs on the raw code bytes, so a
    /// non-matching code is skipped without materializing any `String`. Codes
    /// are visited in code order.
    func forEachMatchingCode(
        where matches: (UnsafeBufferPointer<UInt8>, Range<Int>) -> Bool,
        _ body: (_ code: String, _ values: [String]) -> Void
    ) {
        buf.withUnsafeBufferPointer { p in
            var k = 0
            while k < entries.count {
                let first = entries[k]
                var j = k + 1
                while j < entries.count, sameCode(p, entries[j], first) { j += 1 }
                let codeRange = Int(first.codeStart) ..< Int(first.codeEnd)
                if matches(p, codeRange) {
                    var values = [String]()
                    values.reserveCapacity(j - k)
                    for m in k ..< j {
                        let entry = entries[m]
                        values.append(String(decoding: p[Int(entry.valStart) ..< Int(entry.valEnd)], as: UTF8.self))
                    }
                    body(String(decoding: p[codeRange], as: UTF8.self), values)
                }
                k = j
            }
        }
    }

    // MARK: - Byte-range helpers

    private func lowerBound(_ p: UnsafeBufferPointer<UInt8>, _ key: [UInt8]) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compareCode(p, entries[mid], key) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func compareCode(_ p: UnsafeBufferPointer<UInt8>, _ entry: Entry, _ key: [UInt8]) -> Int {
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

    private func isExact(_ p: UnsafeBufferPointer<UInt8>, _ entry: Entry, _ key: [UInt8]) -> Bool {
        guard Int(entry.codeEnd - entry.codeStart) == key.count else { return false }
        let start = Int(entry.codeStart)
        for k in 0 ..< key.count where p[start + k] != key[k] { return false }
        return true
    }

    private func sameCode(_ p: UnsafeBufferPointer<UInt8>, _ lhs: Entry, _ rhs: Entry) -> Bool {
        let len = Int(lhs.codeEnd - lhs.codeStart)
        guard Int(rhs.codeEnd - rhs.codeStart) == len else { return false }
        let ls = Int(lhs.codeStart), rs = Int(rhs.codeStart)
        for k in 0 ..< len where p[ls + k] != p[rs + k] { return false }
        return true
    }
}

nonisolated private let tab = UInt8(ascii: "\t")
nonisolated private let newline = UInt8(ascii: "\n"), carriage = UInt8(ascii: "\r")
nonisolated private let hash = UInt8(ascii: "#")
