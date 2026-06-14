#!/usr/bin/env swift
//
// FontCoverageTagger.swift — convert a .cin character table into a flat
// `code<TAB>char` table, tagging each char with the minimum macOS major version
// whose bundled fonts can render it.
//
// Interface (HandleExternalResources processor convention):
//   ./FontCoverageTagger.swift <input.cin> <output.txt> <source-url> [section]
//
// "section" selects which block to emit from a cin / cin2 source:
//   chardef (default) — %chardef entries, excluding any nested %symboldef block,
//                       and dropping pure-digit codes (unreachable as compositions).
//   symboldef         — only the %symboldef block (symbol groups).
//
// Coverage comes from FontCoverageMacOS<major>.txt files sitting next to this
// script (produced by FontCoverageRanges.swift, one per OS version). The third
// column of each emitted row is:
//   blank   — renderable since the oldest coverage version (the baseline)
//   <major> — first renderable on that macOS major (e.g. 15, 26)
//   -       — not renderable on any available coverage version
// Those tables are declared as build dependencies via the sidecar
// FontCoverageTagger.swift.inputs, so updating a coverage table regenerates
// the output. Output is independent of the machine running this script.
//
// Diagnostics (coverage versions, tag counts) go to stderr.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 5 else {
    let name = (arguments[0] as NSString).lastPathComponent
    FileHandle.standardError.write(
        Data("Usage: \(name) <input.cin> <output.txt> <source-url> [chardef|symboldef]\n".utf8))
    exit(2)
}
let inputPath = arguments[1]
let outputPath = arguments[2]
let sourceURL = arguments[3]
let section = arguments.count == 5 ? arguments[4] : "chardef"
guard section == "chardef" || section == "symboldef" else {
    FileHandle.standardError.write(Data("✗ Unknown section '\(section)' (chardef|symboldef)\n".utf8))
    exit(2)
}

// MARK: Coverage tables

// Parse a FontCoverageRanges.swift output (lines "U+XXXX [U+YYYY] count") into a
// set of renderable scalar values.
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
let coveragePrefix = "FontCoverageMacOS"
let coverageSuffix = ".txt"
var coverageByMajor: [Int: Set<UInt32>] = [:]
if let entries = try? FileManager.default.contentsOfDirectory(
    at: scriptDir, includingPropertiesForKeys: nil) {
    for url in entries {
        let name = url.lastPathComponent
        guard name.hasPrefix(coveragePrefix), name.hasSuffix(coverageSuffix),
              let major = Int(name.dropFirst(coveragePrefix.count).dropLast(coverageSuffix.count))
        else { continue }
        coverageByMajor[major] = loadCoverage(url)
    }
}
guard !coverageByMajor.isEmpty else {
    FileHandle.standardError.write(
        Data("✗ No \(coveragePrefix)<major>\(coverageSuffix) found next to the processor\n".utf8))
    exit(1)
}
let sortedMajors = coverageByMajor.keys.sorted()
let baselineMajor = sortedMajors.first!
let coverageVersions = sortedMajors.map(String.init).joined(separator: ", ")

// The minimum-version tag for a value: blank if renderable on the baseline
// (oldest) coverage version, else the first major that renders it, else "-".
// Memoized by value (many codes share characters).
var tagCache: [String: String] = [:]
func minVersionTag(_ value: String) -> String {
    if let cached = tagCache[value] { return cached }
    let scalars = value.unicodeScalars
    var tag = "-"
    for major in sortedMajors where
        scalars.allSatisfy({ coverageByMajor[major]!.contains($0.value) }) {
        tag = major == baselineMajor ? "" : String(major)
        break
    }
    tagCache[value] = tag
    return tag
}

// MARK: Emit

guard let input = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(inputPath)\n".utf8))
    exit(1)
}

var outputLines: [String] = [
    "# Character table flagged with the minimum macOS version that can display each char.",
    "# format: code<TAB>char  (trailing <TAB>tag: a major like 15 or 26 = min macOS; - = not shown on latest tested; blank = shown since macOS \(baselineMajor))",
    "# source: \(sourceURL)",
    "# coverage versions: \(coverageVersions)",
    "# generated by Scripts/FontCoverageTagger.swift via HandleExternalResources — DO NOT EDIT",
    "",
]
// %symboldef nests in %chardef: chardef mode emits the outer entries, symboldef the inner.
var inChardef = false
var inSymboldef = false
var tagCounts: [String: Int] = [:]

for rawLine in input.components(separatedBy: "\n") {
    let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.hasPrefix("%") {
        if trimmed.hasPrefix("%chardef begin") { inChardef = true }
        else if trimmed.hasPrefix("%chardef end") { inChardef = false }
        else if trimmed.hasPrefix("%symboldef begin") { inSymboldef = true }
        else if trimmed.hasPrefix("%symboldef end") { inSymboldef = false }
        continue
    }
    let active = section == "symboldef" ? inSymboldef : (inChardef && !inSymboldef)
    if !active || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[1].isEmpty else { continue }
    let code = String(parts[0])
    let value = String(parts[1])
    // Pure-digit codes (e.g. `1` → `1`) aren't reachable as compositions; drop them.
    if section == "chardef" && code.allSatisfy(\.isNumber) { continue }
    let tag = minVersionTag(value)
    outputLines.append(tag.isEmpty ? "\(code)\t\(value)" : "\(code)\t\(value)\t\(tag)")
    tagCounts[tag.isEmpty ? "baseline" : tag, default: 0] += 1
}

let output = outputLines.joined(separator: "\n") + "\n"
try output.write(toFile: outputPath, atomically: true, encoding: .utf8)

let err = FileHandle.standardError
err.write(Data("coverage versions: \(coverageVersions)\n".utf8))
let summary = tagCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
err.write(Data("tag counts: \(summary)\n".utf8))
