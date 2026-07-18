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

Pre-alpha. Milestone 1: MacishType's `ExampleEngine` types end-to-end,
unmodified.

## Development

```sh
cmake -B build
cmake --build build -j
scripts/dev-install.sh    # installs into ~/.local, no root needed
scripts/dev-restart.sh    # restarts fcitx5 with FCITX_ADDON_DIRS set
```

## License

MIT, same as MacishType. `runtime.js` is copied from the MacishType
repository; its provenance commit is recorded in the file header.
