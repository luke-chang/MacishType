#!/usr/bin/env python3
"""Generate a panel badge icon for an engine as a standalone SVG.

Usage:
    GenerateIcon.py <glyph> <output.svg>

    glyph        one CJK character or up to two Latin letters (e.g. "例", "MT")
    output.svg   destination path; name it *-symbolic.svg so desktop panels
                 recolor it to the panel foreground (the Linux counterpart of
                 a macOS template image)

Mirrors macos/Scripts/GenerateIcon.swift's visual spec: a 16pt rounded
rectangle (corner radius 3.5) with the glyph knocked out to transparency,
0.75 font scale for a single glyph / 0.55 for a pair, medium weight. The
glyph outline is baked into the SVG as path geometry (via fontconfig +
fontTools), so the badge renders identically regardless of the fonts
installed where it is displayed. The outline's ink box is centered exactly;
text-based SVGs sit visibly low under librsvg's baseline handling.

The whole badge is a single even-odd path — rectangle and glyph contours
together — so the knockout is a real hole in the geometry. Symbolic
recoloring (GTK/GNOME) works by overriding every fill in the document, which
destroys luminance masks; geometry survives it.

The output also follows KDE's recoloring convention (a stylesheet with
id="current-color-scheme" that KIconLoader rewrites, applied through
class="ColorScheme-Text" and fill="currentColor"). GNOME's fill override
outranks all of it, so one file serves both desktops; anything that
recolors through neither sees the stylesheet's near-black default.

Requires: fc-match (fontconfig), python3-fonttools.
"""

import subprocess
import sys

try:
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont
except ImportError:
    print("error: fontTools is required (Debian/Ubuntu: python3-fonttools)",
          file=sys.stderr)
    sys.exit(1)

CANVAS = 16
CORNER_RADIUS = 3.5


def match_font(codepoints):
    charset = " ".join(f"{cp:x}" for cp in codepoints)
    pattern = f"sans-serif:weight=medium:charset={charset}"
    result = subprocess.run(
        ["fc-match", "-f", "%{file}\t%{index}", pattern],
        capture_output=True, text=True, check=True)
    file, index = result.stdout.split("\t")
    return file, int(index)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)
    glyph_text, output_path = sys.argv[1], sys.argv[2]

    codepoints = [ord(character) for character in glyph_text]
    if not 1 <= len(codepoints) <= 2:
        print("error: glyph must be one character or a pair (e.g. 例, MT)",
              file=sys.stderr)
        sys.exit(1)
    font_size = CANVAS * (0.55 if len(codepoints) > 1 else 0.75)

    font_file, font_index = match_font(codepoints)
    font = TTFont(font_file, fontNumber=font_index, lazy=True)
    units_per_em = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    glyph_set = font.getGlyphSet()

    # Measure the ink bounds first: glyphs laid out along the advance axis
    # in font units.
    bounds_pen = BoundsPen(glyph_set)
    glyph_names = []
    pen_x = 0
    for codepoint in codepoints:
        glyph_name = cmap.get(codepoint)
        if glyph_name is None:
            print(f"error: {font_file} has no glyph for "
                  f"U+{codepoint:04X}", file=sys.stderr)
            sys.exit(1)
        glyph_names.append(glyph_name)
        glyph_set[glyph_name].draw(
            TransformPen(bounds_pen, (1, 0, 0, 1, pen_x, 0)))
        pen_x += glyph_set[glyph_name].width
    if bounds_pen.bounds is None:
        print("error: glyph has an empty outline", file=sys.stderr)
        sys.exit(1)
    ink_y_center = (bounds_pen.bounds[1] + bounds_pen.bounds[3]) / 2

    # Bake the full font-to-canvas transform into the glyph coordinates:
    # advance-centered horizontally (as macOS does), ink-centered
    # vertically, y axis flipped.
    scale = font_size / units_per_em
    translate_x = CANVAS / 2 - pen_x * scale / 2
    translate_y = CANVAS / 2 + ink_y_center * scale
    svg_pen = SVGPathPen(glyph_set, ntos=lambda value: f"{value:.3f}")
    pen_x = 0
    for glyph_name in glyph_names:
        transform = (scale, 0, 0, -scale,
                     translate_x + pen_x * scale, translate_y)
        glyph_set[glyph_name].draw(TransformPen(svg_pen, transform))
        pen_x += glyph_set[glyph_name].width

    inset = CANVAS - CORNER_RADIUS
    rounded_rect = (
        f"M {CORNER_RADIUS} 0 H {inset} "
        f"A {CORNER_RADIUS} {CORNER_RADIUS} 0 0 1 {CANVAS} {CORNER_RADIUS} "
        f"V {inset} "
        f"A {CORNER_RADIUS} {CORNER_RADIUS} 0 0 1 {inset} {CANVAS} "
        f"H {CORNER_RADIUS} "
        f"A {CORNER_RADIUS} {CORNER_RADIUS} 0 0 1 0 {inset} "
        f"V {CORNER_RADIUS} "
        f"A {CORNER_RADIUS} {CORNER_RADIUS} 0 0 1 {CORNER_RADIUS} 0 Z")

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <style type="text/css" id="current-color-scheme">.ColorScheme-Text{{color:#232629;}}</style>
  </defs>
  <path class="ColorScheme-Text" fill="currentColor" fill-rule="evenodd"
        d="{rounded_rect} {svg_pen.getCommands()}"/>
</svg>
"""
    with open(output_path, "w", encoding="utf-8") as output:
        output.write(svg)
    print(f"wrote {output_path} ({font_file}#{font_index})", file=sys.stderr)


if __name__ == "__main__":
    main()
