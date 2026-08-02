#!/usr/bin/env swift
//
// FontCoverageRanges.swift — enumerate every Unicode scalar and report which
// ones the macOS-bundled fonts can render, compressed into contiguous ranges.
//
// The FontCoverageMacOS<major>.txt outputs are committed per-OS snapshots of
// bundled-font coverage. Run once per OS version — the result reflects that
// machine's bundled fonts — then commit the output; coverage tooling reads the
// snapshots to judge which macOS version can display a given character.
//
//   ./FontCoverageRanges.swift [output.txt]
//
// With no argument the output is written next to this script as
// FontCoverageMacOS<major>.txt (e.g. FontCoverageMacOS26.txt), so running it
// unchanged on each OS version yields version-stamped files ready to diff.
//
// Coverage is judged ONLY against macOS-bundled fonts (anywhere under
// /System/Library/, plus the hidden system UI font); the LastResort placeholder
// is excluded. The base font (override with CIN_BASE_FONT) is folded in first.
//
// Diagnostics (font count, renderable total, range count) go to stderr.
//
import AppKit
import CoreText
import Foundation

let osVersion = ProcessInfo.processInfo.operatingSystemVersion
let osVersionString = ProcessInfo.processInfo.operatingSystemVersionString

let outputPath: String
if CommandLine.arguments.count >= 2 {
    outputPath = CommandLine.arguments[1]
} else {
    let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    let fileName = "FontCoverageMacOS\(osVersion.majorVersion).txt"
    outputPath = scriptDir.isEmpty ? fileName : "\(scriptDir)/\(fileName)"
}
let baseFontName = ProcessInfo.processInfo.environment["CIN_BASE_FONT"] ?? "PingFang TC"
let systemFontsRoot = "/System/Library/"

// Merge every bundled-font character set into one, so each scalar needs a single
// membership test rather than a scan across hundreds of faces.
let union = NSMutableCharacterSet()
func add(_ characterSet: CFCharacterSet) { union.formUnion(with: characterSet as CharacterSet) }

add(CTFontCopyCharacterSet(CTFontCreateWithName(baseFontName as CFString, 16, nil)))
if let systemUIFont = CTFontCreateUIFontForLanguage(.system, 16, nil) {
    add(CTFontCopyCharacterSet(systemUIFont))
}
var fontCount = 2

let collection = CTFontCollectionCreateFromAvailableFonts(nil)
if let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] {
    for descriptor in descriptors {
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        if (CTFontCopyPostScriptName(font) as String).contains("LastResort") { continue }
        let path = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path ?? ""
        guard path.hasPrefix(systemFontsRoot) else { continue }
        add(CTFontCopyCharacterSet(font))
        fontCount += 1
    }
}
let merged = union as CharacterSet

var lines: [String] = [
    "# macOS bundled-font coverage, contiguous renderable ranges.",
    "# format: U+XXXX U+YYYY count   (inclusive; a single scalar omits the end)",
    "# os: \(osVersionString)",
    "# base font: \(baseFontName)   bundled fonts merged: \(fontCount)",
    "",
]

var renderableTotal = 0
var rangeStart: UInt32? = nil
var rangeEnd: UInt32 = 0

func flushRange() {
    guard let start = rangeStart else { return }
    let count = Int(rangeEnd - start + 1)
    if start == rangeEnd {
        lines.append(String(format: "U+%04X        %d", start, count))
    } else {
        lines.append(String(format: "U+%04X U+%04X  %d", start, rangeEnd, count))
    }
    rangeStart = nil
}

for codePoint in UInt32(0)...UInt32(0x10FFFF) {
    // Unicode.Scalar(_:) returns nil for surrogates (U+D800–DFFF).
    guard let scalar = Unicode.Scalar(codePoint) else { continue }
    if merged.contains(scalar) {
        renderableTotal += 1
        if rangeStart == nil { rangeStart = codePoint }
        rangeEnd = codePoint
    } else {
        flushRange()
    }
}
flushRange()

let body = lines.joined(separator: "\n") + "\n"
try body.write(toFile: outputPath, atomically: true, encoding: .utf8)

let err = FileHandle.standardError
err.write(Data("bundled fonts merged: \(fontCount)\n".utf8))
err.write(Data("renderable scalars: \(renderableTotal)\n".utf8))
err.write(Data("ranges: \(lines.count - 4)\n".utf8))
