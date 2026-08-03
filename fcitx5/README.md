# fcitx5-macishtype

The Linux port of MacishType: a Fcitx5 addon that runs JavaScript input
method engines on an embedded
[quickjs-ng](https://github.com/quickjs-ng/quickjs) runtime. Any engine
written against the MacishType contract ([`engines/`](../engines/)) — the
ones bundled in this repo or one you write yourself — runs unmodified on
this host and on the macOS one ([`macos/`](../macos/)).

## Highlights

- One addon, many input methods — every engine folder becomes its own fcitx5
  input method (`macishtype-<name>`), switchable like any other IM
- Write engines in JavaScript — engine folders hot-reload on edit, no fcitx5
  restart needed
- Native settings — manifest `settings` render per input method in
  `fcitx5-configtool` and reach the live engine immediately
- Panel integration — engine labels and SVG icons show in the status area
  and the input-method switcher

## Environment

### Runtime

- Linux with fcitx5 (developed and tested against 5.1.x)

### Development

- A C++20 compiler, CMake ≥ 3.16, Ninja, pkg-config
- Fcitx5, fontconfig, ICU, and gettext development files
- `curl` + `python3` for the data-table pipeline (`make prepare`)
- Tests additionally need `python3-gi`, `dbus-run-session`, and an installed
  fcitx5 to run against

On Debian/Ubuntu, everything above is:

```sh
sudo apt install build-essential cmake ninja-build pkgconf git \
    fcitx5-modules-dev libfcitx5core-dev libfontconfig-dev libicu-dev \
    gettext curl python3 python3-gi python3-fonttools dbus
```

## Installation

All `make` commands run from this directory (`fcitx5/`). quickjs-ng is a git
submodule — only this platform needs it — so make sure it is checked out:

```sh
git clone --recurse-submodules …            # fresh clone, or
git submodule update --init --recursive     # existing checkout
```

### First install

1. `make install`
   - Syncs the pinned data tables (`make prepare`), builds, installs into
     `/usr` (asks for sudo), and restarts fcitx5.
2. Add engines: drop or symlink engine folders into
   `~/.local/share/fcitx5/macishtype/engines/<name>/`. The folder name is the
   engine's identity and must be lowercase `[a-z0-9_-]` — anything else is
   skipped at discovery. Symlinks are fine (and are the intended dev
   workflow):

   ```sh
   mkdir -p ~/.local/share/fcitx5/macishtype/engines
   ln -s "$(pwd)/../engines/example" \
       ~/.local/share/fcitx5/macishtype/engines/example
   ```

3. Open `fcitx5-configtool` → **Input Method** → **Add**, and pick the
   engines from the list — each appears as its own input method.

### Upgrade

1. `git pull` and `git submodule update --init --recursive`.
2. `make install` — replaces the installed addon and restarts fcitx5.

### Uninstall

`make uninstall` — removes the production install (per cmake's manifest) and
restarts fcitx5.

## Development

### First-time setup

Same flow as [Installation](#installation), but use `make debug` instead of
`make install`: it dev-installs into `~/.local` (no root) and restarts fcitx5
with `FCITX_ADDON_DIRS` pointing there.

The dev install only works while that variable is set, and fcitx5's
autostart won't have it after a re-login. Make it persistent once — adjust
the home path and the multiarch triplet (`gcc -dumpmachine`) to your system:

```sh
cat > ~/.config/environment.d/90-fcitx5-macishtype.conf <<'EOF'
FCITX_ADDON_DIRS=/home/YOU/.local/lib/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5
EOF
```

Notes:

- The variable REPLACES fcitx5's default search path; keep the system
  directory listed or every other addon breaks.
- `environment.d` is read at login; use `make restart` to apply immediately.
- **Skipping this bites after the next re-login**: the autostarted fcitx5
  comes up without the variable, fails to load the addon, and prunes its
  input methods from `~/.config/fcitx5/profile` on save.
- Before a production `make install`, run `make dev-uninstall` — user-dir
  files shadow the system install.

### Iteration loop

After a code change:

- `make debug` — rebuild and dev-install in one step (restarts fcitx5, which
  interrupts typing).
- `make test` — acceptance suite against an isolated fcitx5; safe to run any
  time (needs the `example` engine symlink from First install).
- `make log` — follow the addon's log, scoped to this platform's sources.
- `make log-js` — follow engine `console.*` output only.
- `make log-history` — show recent log history (default 1h;
  `LOG_SHOW_LAST=24h …`).

Engine edits need none of this: engine folders hot-reload on the next
keystroke.

### Other targets

- `make build` — cmake configure + build without installing.
- `make prepare` — sync the pinned data tables (incremental; auto-run by
  debug/install).
- `make restart` — restart fcitx5; `LOG_DEBUG=1` enables per-key Debug
  logging (including engine `console.debug`).
- `make clean` — remove the build directory.

## Writing an engine

Engines are cross-platform; everything lives one level up:

- [`engines/README.md`](../engines/README.md) — full engine-writing guide
  (manifest, lifecycle, event mutators, settings schema, runtime globals),
  including per-host support notes
- [`engines/example/`](../engines/example/) — reference engine to copy and
  edit
- [`engines/utils/MacishType.d.ts`](../engines/utils/MacishType.d.ts) —
  TypeScript definitions for IDE autocomplete, type checking, and bundler
  integration

Host notes for this platform:

- Manifest `settings` render "equivalent or hidden": `toggle`, `textField`,
  integer `number`, and `picker` show in configtool; other field kinds stay
  hidden with their manifest defaults still applied.
- Custom manifest `menu` items are not implemented yet: they get no UI, and
  `menuchange` never fires.
- The candidate window is fcitx5's own themed one: `layoutDirection`,
  `pageSize`, `indexLabels`, and the navigation/index-label key options are
  honored; the appearance knobs (`fontSize`, `expandable`, …) and
  `updateCandidates`' `anchorAt` are accepted but have no effect.
- `navigator.languages` and the `fontCoverage` module are load-time
  snapshots: `languagechange` and `fontcoveragechange` never fire on this
  host. Changing the system language or installing fonts takes a re-login
  on Linux anyway, which restarts fcitx5 and reloads engines.
- Ship an SVG icon (`icon-symbolic.svg` preferred): SVGs are served to every
  panel through the icon theme, while a PNG only reaches panels that accept
  file paths.
- `Intl` is provided on top of quickjs-ng, backed by the system ICU — a
  common option subset of `Segmenter`, `DateTimeFormat`, `NumberFormat`,
  `PluralRules`, and `Collator`.
