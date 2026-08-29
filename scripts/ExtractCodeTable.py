#!/usr/bin/env python3
"""Produce a flat `code<TAB>value` table from a .cin / .cin2 file or a raw
`code<TAB>value` TSV. Blank lines, comments, and malformed lines (no tab, or
an empty code/value) are dropped.

Interface (external-resources processor convention):
  ExtractCodeTable.py <input> <output.txt> <source-url> [section]

"section" scopes extraction to one named cin2 block (%<section> begin..end):
  chardef      — the outer %chardef entries, excluding any nested %symboldef
                 block, and dropping pure-digit codes (unreachable as
                 compositions).
  symboldef    — only the nested %symboldef block (symbol groups).
  quickphrases — emit each `code<TAB>value` verbatim.
  quick        — each row packs N positional candidates; emit one sparse line
                 `code+slotKey<TAB>value` per non-empty slot (skipping the
                 %nullcandidate placeholder), where slot keys are 1234567890.
The section walker is nesting-aware: it matches `%<name> begin..end` exactly
and suppresses any nested sub-block, so chardef doesn't leak symboldef and
vice versa. With no section, the legacy behavior applies: a .cin emits its
%chardef entries, a raw TSV passes through.
"""

import os
import sys

KNOWN_SECTIONS = ("chardef", "symboldef", "quick", "quickphrases")


def code_value(line):
    """Split a `code<TAB>value` line; None for malformed (no tab, empty parts)."""
    code, tab, value = line.partition("\t")
    if not tab or not code or not value.strip():
        return None
    return code, value


def main():
    if len(sys.argv) not in (4, 5):
        name = os.path.basename(sys.argv[0])
        print(f"Usage: {name} <input> <output.txt> <source-url>"
              " [chardef|symboldef|quick|quickphrases]", file=sys.stderr)
        sys.exit(2)
    input_path, output_path, source_url = sys.argv[1:4]
    section = sys.argv[4] if len(sys.argv) == 5 else None
    if section is not None and section not in KNOWN_SECTIONS:
        print(f"✗ Unknown section '{section}'"
              " (chardef|symboldef|quick|quickphrases)", file=sys.stderr)
        sys.exit(2)

    try:
        with open(input_path, encoding="utf-8") as source:
            text = source.read()
    except OSError as error:
        print(f"✗ Cannot read {input_path}: {error}", file=sys.stderr)
        sys.exit(1)
    lines = [line[:-1] if line.endswith("\r") else line
             for line in text.split("\n")]

    def section_lines(name):
        """Data lines of one named cin2 block (%<name> begin .. %<name> end),
        matching the markers exactly so `quick` doesn't also capture
        `quickphrases`. Nesting-aware: while inside the target block, any
        nested `%<x> begin..end` (e.g. %symboldef inside %chardef) is
        suppressed, so the target's data lines don't leak the nested block and
        the nested `%<x> end` doesn't prematurely close the target."""
        result = []
        in_section = False
        nested_depth = 0
        for line in lines:
            trimmed = line.strip()
            if not in_section:
                if trimmed == f"%{name} begin":
                    in_section = True
                continue
            if nested_depth == 0 and trimmed == f"%{name} end":
                in_section = False
                continue
            if trimmed.startswith("%"):
                if trimmed.endswith(" begin"):
                    nested_depth += 1
                elif trimmed.endswith(" end") and nested_depth > 0:
                    nested_depth -= 1
                continue
            if nested_depth > 0 or not trimmed or trimmed.startswith("#"):
                continue
            result.append(line)
        return result

    def directive(name):
        """The trailing token of a single-value cin header directive
        (`%<name> <value>`)."""
        for line in lines:
            trimmed = line.strip()
            if not trimmed.startswith(f"%{name}"):
                continue
            rest = trimmed[len(name) + 1:].strip()
            if rest:
                return rest
        return None

    def emit_pairs(name, skip=lambda code: False):
        pairs = []
        for line in section_lines(name):
            split = code_value(line)
            if split and not skip(split[0]):
                pairs.append(f"{split[0]}\t{split[1]}")
        return pairs

    entries = []
    if section == "chardef":
        # Pure-digit codes (e.g. `1` → `1`) aren't reachable as compositions.
        entries = emit_pairs(
            "chardef", skip=lambda code: all(c in "0123456789" for c in code))
    elif section == "symboldef":
        entries = emit_pairs("symboldef")
    elif section == "quickphrases":
        entries = emit_pairs("quickphrases")
    elif section == "quick":
        null_candidate = directive("nullcandidate") or "□"
        slot_keys = "1234567890"
        for line in section_lines("quick"):
            split = code_value(line)
            if not split:
                continue
            code, packed = split
            # One code point per slot; the pinned data has no multi-code-point
            # candidates.
            for slot, char in enumerate(packed):
                if slot < len(slot_keys) and char != null_candidate:
                    entries.append(f"{code}{slot_keys[slot]}\t{char}")
    else:
        # Legacy: a .cin emits its %chardef block; a raw TSV passes through.
        is_cin = "%chardef begin" in text
        in_chardef = False
        for line in lines:
            trimmed = line.strip()
            if trimmed.startswith("%"):
                if trimmed.startswith("%chardef begin"):
                    in_chardef = True
                elif trimmed.endswith("end"):
                    in_chardef = False
                continue
            if not trimmed or trimmed.startswith("#"):
                continue
            if is_cin and not in_chardef:
                continue
            if code_value(line) is None:
                continue
            entries.append(line)

    # chardef / quickphrases feed a byte-range table that binary-searches by
    # code; emitting them code-sorted (stable, so a code's candidates keep
    # source order) lets the runtime skip its own sort. Byte order matches the
    # runtime's UTF-8 comparison. Other sections keep source order (their
    # consumers depend on it — e.g. quick's slot order is the selection-key
    # order).
    if section in ("chardef", "quickphrases"):
        entries.sort(key=lambda entry: entry.split("\t", 1)[0].encode())

    output = "\n".join([
        "# Code-to-value lookup table.",
        "# format: code<TAB>value",
        f"# source: {source_url}",
        "# generated by scripts/ExtractCodeTable.py via external-resources"
        " — DO NOT EDIT",
        "",
        *entries,
    ]) + "\n"
    try:
        with open(output_path, "w", encoding="utf-8", newline="\n") as sink:
            sink.write(output)
    except OSError as error:
        print(f"✗ Cannot write {output_path}: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"wrote {len(entries)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
