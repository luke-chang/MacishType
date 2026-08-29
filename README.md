# MacishType

A macOS input method that replicates the native input experience — a
system-look candidate window, built-in input methods (currently Array 行列),
and user extension through external JavaScript engines and drop-in `.cin`
tables.

The JavaScript engine contract is cross-platform: the same engine folder
runs unmodified on the Linux host, a fcitx5 addon in [`fcitx5/`](fcitx5/).

## Repository layout

- [`macos/`](macos/) — the macOS input method: InputMethodKit host, candidate window, Settings UI, and build system
- [`fcitx5/`](fcitx5/) — the Linux input method: fcitx5 addon and build system
- [`jshost/`](jshost/) — the platform-independent QuickJS engine host the fcitx5 addon embeds; owns the quickjs-ng submodule
- [`engines/`](engines/) — cross-platform JavaScript engines and the engine contract ([`README.md`](engines/README.md), mirrored in TypeScript by [`utils/MacishType.d.ts`](engines/utils/MacishType.d.ts))
- [`shared/`](shared/) — the platform-independent library every host links (log facade, ICU grapheme cache, UTF-8 validation, associated-phrase dictionary) plus [`js/globals.js`](shared/js/globals.js), the contract globals every host evaluates before an engine
- [`scripts/`](scripts/) — the shared external-resources pipeline; `make prepare` on either platform downloads the pinned data tables into `tables/` at the repo root (gitignored)
- [`artwork/`](artwork/) — archival originals of the app icon, kept for reference

## Start here

- Installing or developing on macOS: [`macos/README.md`](macos/README.md)
- Installing or developing on Linux: [`fcitx5/README.md`](fcitx5/README.md) (note: building needs the quickjs-ng submodule — clone with `--recurse-submodules`)
- Writing an engine: [`engines/README.md`](engines/README.md)

## Acknowledgments

Data tables downloaded and bundled by `make prepare` (each upstream's license, if any, ships alongside its data):

- **Associated-phrase** and **per-character frequency** tables — derived from the phrase corpus of [McBopomofo](https://github.com/openvanilla/McBopomofo), under its [MIT License](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt).
- **Symbol-name** table — derived from [Unicode CLDR](https://github.com/unicode-org/cldr-json) annotations, under the [Unicode License](https://github.com/unicode-org/cldr-json/blob/main/LICENSE).
- **Array30 code tables** — derived from [gontera/array30](https://github.com/gontera/array30), under its license for use by third-party input methods.

## License

See [LICENSE](LICENSE).
