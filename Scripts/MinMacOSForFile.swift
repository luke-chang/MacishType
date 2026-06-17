#!/usr/bin/env swift
//
// MinMacOSForFile.swift — report the lowest macOS version whose bundled fonts
// can fully display a file's text, using the committed FontCoverageMacOS<major>.txt
// snapshots. Useful before adding a new dictionary table: it tells you whether
// the table reaches beyond the baseline (supplementary-plane chars) or includes
// characters no tested OS ships a font for — i.e. which character-set scope
// options a future engine should offer.
//
//   ./MinMacOSForFile.swift <input-file>
//
// Reads every FontCoverageMacOS<major>.txt next to this script. For each unique
// scalar in the input, the requirement is the lowest major whose snapshot covers
// it; the file's minimum is the max across scalars. Scalars no snapshot covers
// are "unsupported" (need a newer-than-tested OS, or an installed font).
//
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    let name = (arguments[0] as NSString).lastPathComponent
    FileHandle.standardError.write(Data("Usage: \(name) <input-file>\n".utf8))
    exit(2)
}
let inputPath = arguments[1]

// MARK: Coverage snapshots

// Parse a FontCoverageRanges.swift output ("U+XXXX [U+YYYY] count") into the set
// of renderable scalars; the trailing count column is ignored.
func loadCoverage(_ url: URL) -> Set<UInt32> {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var set = Set<UInt32>()
    func hex(_ token: Substring) -> UInt32? {
        token.hasPrefix("U+") ? UInt32(token.dropFirst(2), radix: 16) : nil
    }
    for line in text.split(separator: "\n") {
        guard line.hasPrefix("U+") else { continue }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let start = hex(tokens[0]) else { continue }
        var end = start
        if tokens.count >= 2, let parsed = hex(tokens[1]) { end = parsed }
        if start <= end { for scalar in start...end { set.insert(scalar) } }
    }
    return set
}

let scriptDir = URL(fileURLWithPath: (arguments[0] as NSString).deletingLastPathComponent)
let prefix = "FontCoverageMacOS", suffix = ".txt"
var coverageByMajor: [Int: Set<UInt32>] = [:]
if let entries = try? FileManager.default.contentsOfDirectory(at: scriptDir, includingPropertiesForKeys: nil) {
    for url in entries {
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              let major = Int(name.dropFirst(prefix.count).dropLast(suffix.count)) else { continue }
        coverageByMajor[major] = loadCoverage(url)
    }
}
guard !coverageByMajor.isEmpty else {
    FileHandle.standardError.write(Data("✗ No \(prefix)<major>\(suffix) snapshots found next to the script\n".utf8))
    exit(1)
}
let majors = coverageByMajor.keys.sorted()
let baseline = majors.first!

// Lowest major whose snapshot covers a scalar, or nil if none do.
func requiredMajor(_ value: UInt32) -> Int? {
    for major in majors where coverageByMajor[major]!.contains(value) { return major }
    return nil
}

// MARK: Scan input

guard let text = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("✗ Cannot read \(inputPath)\n".utf8))
    exit(1)
}

var seen = Set<UInt32>()
var scalarsByMajor: [Int: [UInt32]] = [:]
var unsupported: [UInt32] = []
for scalar in text.unicodeScalars where seen.insert(scalar.value).inserted {
    if let major = requiredMajor(scalar.value) { scalarsByMajor[major, default: []].append(scalar.value) }
    else { unsupported.append(scalar.value) }
}
let uniqueCount = seen.count

// MARK: Report

func sample(_ values: [UInt32], limit: Int = 12) -> String {
    values.sorted().prefix(limit).map {
        let glyph = Unicode.Scalar($0).map(String.init) ?? "?"
        return String(format: "%@ U+%04X", glyph, $0)
    }.joined(separator: "  ")
}

print("Snapshots: macOS \(majors.map(String.init).joined(separator: ", "))")
print("File: \(inputPath)  (\(uniqueCount) unique scalars)")

let highestNeeded = scalarsByMajor.keys.max()
if !unsupported.isEmpty {
    print("Minimum macOS: NOT fully displayable on tested OSes (≤ \(majors.last!)) — "
        + "\(unsupported.count) scalar(s) need a newer OS or an installed font.")
} else if let needed = highestNeeded {
    let note = needed == baseline ? " (baseline)" : ""
    print("Minimum macOS to fully display: \(needed)\(note)")
} else {
    print("Minimum macOS to fully display: (no displayable scalars found)")
}

print("Breakdown:")
for major in majors {
    let count = scalarsByMajor[major]?.count ?? 0
    let label = major == baseline ? "macOS \(major) (baseline)" : "macOS \(major)"
    print("  \(label): \(count)")
    if major != baseline, let values = scalarsByMajor[major], !values.isEmpty {
        print("    e.g. \(sample(values))")
    }
}
if !unsupported.isEmpty {
    print("  unsupported: \(unsupported.count)")
    print("    e.g. \(sample(unsupported))")
}
