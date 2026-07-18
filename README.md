# fcitx5-macishtype

A Fcitx5 addon that hosts [MacishType](https://github.com/luke-chang/MacishType)
JavaScript input method engines on Linux, embedding
[quickjs-ng](https://github.com/quickjs-ng/quickjs) as the JS runtime.

The goal: engines written against the MacishType JS contract
(`Engines/*/index.js` + `manifest.json`) run **unmodified** on both macOS
(MacishType, JavaScriptCore) and Linux (this addon, QuickJS).

## How it works

- One addon, many input methods: engine folders are discovered at startup and
  each becomes an independent Fcitx5 input method (`macishtype-<name>`) via
  `listInputMethods()`, switchable like any other IM.
- Engine folders live in the layered XDG location
  `~/.local/share/fcitx5/macishtype/engines/<name>/` (user) and
  `/usr/share/fcitx5/macishtype/engines/<name>/` (system). Folder names are
  the stable identity: lowercase `[a-z0-9_-]` only, no `Engine` postfix —
  e.g. `example`, not `ExampleEngine`. Symlinks are fine (and are the
  intended dev workflow).
- Each engine gets its own QuickJS context. The addon re-registers the same
  `__MacishType_*` bridge globals the macOS host provides, then loads the
  shared `runtime.js` and the engine's entry module through an `engine:///`
  module loader with path containment.

## Status

Milestone 1 reached: MacishType's `ExampleEngine` types end to end,
unmodified — composition preedit, candidate window with index labels and
navigation, commit, escape, and OS passthrough all work against an isolated
fcitx5 instance (`test/acceptance.sh`).

Not yet implemented: settings/config UI, storage change events, hot reload,
associated-mode dictionary data, reverse lookup, and live
fontcoveragechange events on font installs. All `manifest.modules` data
sources are fed: wordFrequency and symbolNames from the corpora prepared by
`scripts/prepare-data.sh`, fontCoverage from fontconfig.

Traditional→Simplified output is delegated to fcitx5's own chttrans module
(attached automatically for Chinese engines, toggled with its hotkey /
status-area icon, state persisted per input method). The
`outputToSimplified` system menu key proxies the same chttrans state, so
engine-driven toggles and the chttrans hotkey flip one switch.

## Development

```sh
make build     # cmake configure + build
make prepare   # download/convert module data tables (wordFrequency, ...)
make debug     # dev install into ~/.local + fcitx5 restart (interrupts typing)
make test      # acceptance suite against an isolated fcitx5
make install   # production install into the system prefix (sudo)
```

`make debug` needs fcitx5 launched with `FCITX_ADDON_DIRS` pointing at
`~/.local/lib/fcitx5` (a `~/.config/environment.d/` entry makes that stick
across logins); `make install` has no such requirement. The underlying
scripts live in `scripts/` and are directly invokable.

## License

MIT, same as MacishType. `runtime.js` is copied from the MacishType
repository; its provenance commit is recorded in the file header.
