# Array (行列) — JavaScript engine

A complete Array (行列) input method written against the MacishType JavaScript
engine contract. It runs unmodified on every MacishType host and exercises the
JS engine API end to end.

## Setup

1. **Sync the data tables.**

   ```sh
   python3 setup.py
   ```

   This copies the processed Array tables out of the repo's shared `tables/`
   into this folder, running the external-resources pipeline first if they're
   missing. The copied `*.txt` files are generated artifacts and are
   gitignored — re-run the script after a `make prepare` or a resource-lock
   bump.

2. **Load the engine.** How the host finds an engine folder differs per
   platform:

   - **macOS** — open MacishType's **Settings → JS → Engine folder → Choose
     Folder…** and pick this folder.
   - **Linux (fcitx5)** — the addon can ship this engine already: `make
     install PRELOAD_ENGINES=array30` (or `make pkg` with the same variable)
     puts it in the system layer with the data tables in place, so neither
     step here is needed — see
     [`fcitx5/README.md`](../../fcitx5/README.md#first-install). To place it
     by hand instead, put this folder in the addon's engine directory, copied
     or symlinked, then add **Array (行列)** in `fcitx5-configtool` → **Input
     Method** → **Add**:

     ```sh
     mkdir -p ~/.local/share/fcitx5/macishtype/engines
     cp -r "$(pwd)" ~/.local/share/fcitx5/macishtype/engines/array30
     # or symlink instead, to edit the engine in place
     ln -s "$(pwd)" ~/.local/share/fcitx5/macishtype/engines/array30
     ```

   Either way the host watches the folder and hot-reloads on edit, so
   iterating doesn't require restarting the input method.

## Features

- **Short codes** for 1–2 key codes (一/二級簡碼), with fixed selection keys.
- **Paging** through any candidate list with `=` / `]` / `Shift+→` (forward)
  and `-` / `[` / `Shift+←` (back).
- **Phrases** — end the code with `'` (instead of Space) to look up phrases.
- **Wildcards** with `?` (one radical) and `*` (one or more); a leading `*`
  matches any code containing the given radicals in any order.
- **Symbol groups** via `w` / `hg` + digit, shown as a group menu and then a
  named symbol list.
- **Full-width** input, triggered per host: on macOS a one-shot
  `Option` + key commits the full-width form; on fcitx5 it is a mode, toggled
  from the full-width entry in the input method's status area — which needs
  fcitx5's `fullwidth` module installed (`fcitx5-module-fullwidth` on
  Debian-family), and stays absent without it.
- **Character set** picker in the host's engine settings (standard / all
  displayable / full) that filters candidates by installed-font coverage.
- **Error feedback** — input that leads nowhere beeps; a number that selects
  nothing also clears the code. An optional setting marks a short code's empty
  slots with `□`.
- **Reverse lookup** (`capabilities.reverseLookup`) for the host's Find Input
  Code window: main codes as radical readouts, then short codes as
  `readout+selectionKey` annotated 簡碼. macOS opens it from the IME menu;
  fcitx5 from the input method's status area or the hotkey configured in
  `fcitx5-configtool` (default `Ctrl+Alt+L`).

## Tests

Run the suite with Node's built-in test runner (no dependencies); it stubs the
host globals and drives the engine against the real data tables, so run
`python3 setup.py` first.

```sh
node --test engines/array30/index.test.mjs
```
