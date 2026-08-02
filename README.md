# MacishType

An input method that replicates the macOS system look and feel, extensible via external JavaScript engines, now being ported to other platforms. Engines are plain JavaScript shared across platforms through a single contract; each platform ships a native host that runs them.

## Repository layout

- [`macos/`](macos/) — the macOS input method: InputMethodKit host, candidate window, Settings UI, and build system
- [`engines/`](engines/) — cross-platform JavaScript engines and the engine contract ([`utils/MacishType.d.ts`](engines/utils/MacishType.d.ts))
- [`runtime/`](runtime/) — the JavaScript runtime bootstrap every host loads before an engine

## Start here

- Installing or developing on macOS: [`macos/README.md`](macos/README.md)
- Writing an engine: [`engines/README.md`](engines/README.md)

## Acknowledgements

Data tables downloaded and bundled by `make prepare` (each upstream's license, if any, ships alongside its data):

- **Associated-phrase** and **per-character frequency** tables — derived from the phrase corpus of [McBopomofo](https://github.com/openvanilla/McBopomofo), under its [MIT License](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt).
- **Symbol-name** table — derived from [Unicode CLDR](https://github.com/unicode-org/cldr-json) annotations, under the [Unicode License](https://github.com/unicode-org/cldr-json/blob/main/LICENSE).
- **Array30 code tables** — derived from [gontera/array30](https://github.com/gontera/array30), under its license for use by third-party input methods.

## License

See [LICENSE](LICENSE).
