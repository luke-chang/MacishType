#!/usr/bin/env swift
//
// ExtractCodeTable.swift — produce a flat `code<TAB>value` table from a .cin /
// .cin2 file or a raw `code<TAB>value` TSV. Blank lines, comments, and malformed
// lines (no tab, or an empty code/value) are dropped.
//
// Interface (HandleExternalResources processor convention):
//   ./ExtractCodeTable.swift <input> <output.txt> <source-url> [section]
//
// "section" scopes extraction to one named cin2 block (%<section> begin..end):
//   chardef      — the outer %chardef entries, excluding any nested %symboldef
//                  block, and dropping pure-digit codes (unreachable as
//                  compositions).
//   symboldef    — only the nested %symboldef block (symbol groups).
//   quickphrases — emit each `code<TAB>value` verbatim.
//   quick        — each row packs N positional candidates; emit one sparse line
//                  `code+slotKey<TAB>value` per non-empty slot (skipping the
//                  %nullcandidate placeholder), where slot keys are 1234567890.
// The section walker is nesting-aware: it matches `%<name> begin..end` exactly and
// suppresses any nested sub-block, so chardef doesn't leak symboldef and vice
// versa. With no section, the legacy behavior applies: a .cin emits its %chardef
// entries, a raw TSV passes through.

import Foundation

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5 else {
    let name = (args[0] as NSString).lastPathComponent
    FileHandle.standardError.write(
        Data("Usage: \(name) <input> <output.txt> <source-url> [chardef|symboldef|quick|quickphrases]\n".utf8))
    exit(2)
}
let inputPath = args[1]
let outputPath = args[2]
let sourceURL = args[3]
let section = args.count == 5 ? args[4] : nil
let knownSections: Set<String> = ["chardef", "symboldef", "quick", "quickphrases"]
guard section == nil || knownSections.contains(section!) else {
    FileHandle.standardError.write(
        Data("✗ Unknown section '\(section!)' (chardef|symboldef|quick|quickphrases)\n".utf8))
    exit(2)
}

let input: String
do {
    input = try String(contentsOfFile: inputPath, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("✗ Cannot read \(inputPath): \(error)\n".utf8))
    exit(1)
}

let lines = input.components(separatedBy: "\n")

// Data lines of one named cin2 block (%<name> begin .. %<name> end), matching
// the markers exactly so `quick` doesn't also capture `quickphrases`. Nesting-
// aware: while inside the target block, any nested `%<x> begin..end` (e.g.
// %symboldef inside %chardef) is suppressed, so the target's data lines don't
// leak the nested block and the nested `%<x> end` doesn't prematurely close the
// target.
func sectionLines(_ name: String) -> [String] {
    var result: [String] = []
    var inSection = false
    var nestedDepth = 0
    for rawLine in lines {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !inSection {
            if trimmed == "%\(name) begin" { inSection = true }
            continue
        }
        if nestedDepth == 0 && trimmed == "%\(name) end" { inSection = false; continue }
        if trimmed.hasPrefix("%") {
            if trimmed.hasSuffix(" begin") { nestedDepth += 1 }
            else if trimmed.hasSuffix(" end") && nestedDepth > 0 { nestedDepth -= 1 }
            continue
        }
        if nestedDepth > 0 || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        result.append(line)
    }
    return result
}

// Split a `code<TAB>value` line, rejecting malformed ones (no tab, empty parts).
func codeValue(_ line: String) -> (code: Substring, value: Substring)? {
    guard let tab = line.firstIndex(of: "\t") else { return nil }
    let code = line[..<tab]
    let value = line[line.index(after: tab)...]
    if code.isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    return (code, value)
}

// The trailing token of a single-value cin header directive (`%<name> <value>`).
func directive(_ name: String) -> String? {
    for rawLine in lines {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("%\(name)") else { continue }
        let rest = trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { return rest }
    }
    return nil
}

// Emit `code<TAB>value` for each row of a section, optionally skipping some.
func emitPairs(_ name: String, skip: (Substring) -> Bool = { _ in false }) -> [String] {
    sectionLines(name).compactMap { line in
        guard let (code, value) = codeValue(line), !skip(code) else { return nil }
        return "\(code)\t\(value)"
    }
}

var entries: [String] = []
switch section {
case "chardef":
    // Pure-digit codes (e.g. `1` → `1`) aren't reachable as compositions; drop.
    entries = emitPairs("chardef") { $0.allSatisfy(\.isNumber) }
case "symboldef":
    entries = emitPairs("symboldef")
case "quickphrases":
    entries = emitPairs("quickphrases")
case "quick":
    let nullCandidate = directive("nullcandidate") ?? "□"
    let slotKeys = Array("1234567890")
    for line in sectionLines("quick") {
        guard let (code, packed) = codeValue(line) else { continue }
        for (slot, char) in packed.enumerated()
        where slot < slotKeys.count && String(char) != nullCandidate {
            entries.append("\(code)\(slotKeys[slot])\t\(char)")
        }
    }
default:
    // Legacy: a .cin emits its %chardef block; a raw TSV passes through.
    let isCin = input.contains("%chardef begin")
    var inChardef = false
    for rawLine in lines {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("%") {
            if trimmed.hasPrefix("%chardef begin") { inChardef = true }
            else if trimmed.hasSuffix("end") { inChardef = false }
            continue
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if isCin && !inChardef { continue }
        if codeValue(line) == nil { continue }
        entries.append(line)
    }
}

var outputLines: [String] = [
    "# Code-to-value lookup table.",
    "# format: code<TAB>value",
    "# source: \(sourceURL)",
    "# generated by Scripts/ExtractCodeTable.swift via HandleExternalResources — DO NOT EDIT",
    "",
]
outputLines.append(contentsOf: entries)

let output = outputLines.joined(separator: "\n") + "\n"
do {
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("✗ Cannot write \(outputPath): \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("wrote \(entries.count) entries\n".utf8))
