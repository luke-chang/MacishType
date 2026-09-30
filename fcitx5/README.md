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

- Linux with fcitx5 ≥ 5.1.13 — the release that added the `StandardPaths`
  API the addon builds on; older versions do not compile
- `fcitx5-chinese-addons` — engine capabilities delegate to its modules:
  `chttrans` backs `outputToSimplified` and `fullwidth` backs
  `fullwidthInput` (Debian also splits them out as
  `fcitx5-module-chttrans` / `fcitx5-module-fullwidth`). A missing module
  leaves that capability off.
- On GNOME the candidate window is rendered by the kimpanel Shell
  extension: install
  [Input Method Panel](https://extensions.gnome.org/extension/261/kimpanel/)
  (`kimpanel@kde.org`) from extensions.gnome.org. Without it fcitx5 falls
  back to its own classicui window, which works in regular apps but cannot
  appear in GNOME Shell's own text fields (the Overview search, the Alt+F2
  run dialog). A layout bug you may hit after installing it is described in
  [Known issue: kimpanel on GNOME](#known-issue-kimpanel-on-gnome).

### Development

- A C++20 compiler, CMake ≥ 3.25, Ninja, pkg-config
- Fcitx5, fontconfig, ICU, and gettext development files
- `python3` for the data-table pipeline (`make prepare`)
- `python3-fonttools` for the icon generator (`scripts/GenerateIcon.py`)
- Tests additionally need `python3-gi`, `dbus-run-session`, an installed
  fcitx5 to run against, and an available `zh_TW` locale (the suite asserts
  translated labels)

On Debian/Ubuntu, everything above is:

```sh
sudo apt install build-essential cmake ninja-build pkgconf git \
    fcitx5 fcitx5-module-chttrans fcitx5-module-fullwidth \
    fcitx5-modules-dev libfcitx5core-dev libfontconfig-dev libicu-dev \
    gettext python3 python3-gi python3-fonttools dbus
```

On Fedora:

```sh
sudo dnf install gcc-c++ cmake ninja-build pkgconf git gettext \
    fcitx5 fcitx5-devel fcitx5-chinese-addons \
    fontconfig-devel libicu-devel rpm-build \
    python3 python3-gobject python3-fonttools dbus-daemon glibc-langpack-zh
```

## Installation

All `make` commands run from this directory (`fcitx5/`). The embedded
quickjs-ng runtime is a git submodule at `jshost/external/quickjs-ng`
(repo root): clone with `--recurse-submodules`, or run
`git submodule update --init --recursive` in an existing checkout.

### First install

1. `make install`
   - Syncs the pinned data tables (`make prepare`), builds, installs into
     `/usr` (asks for sudo), and restarts fcitx5.
   - `PRELOAD_ENGINES="array30 example"` (space- or comma-separated, or
     `all` for every folder with a manifest) also installs those folders
     from [`engines/`](../engines/) into the system layer, which covers
     step 2 for them. That layer ends up holding exactly
     what the variable asked for, so engines an earlier install put there
     are removed when they are not listed again. Same variable as
     [`make pkg`](#other-targets).
2. `make install-engines`
   - Not needed for the engines step 1 preloaded.
   - Installs engine folders from [`engines/`](../engines/) as copies, or as
     symlinks — the dev workflow, where source edits reach fcitx5 live.
   - By hand: put the folder in
     `~/.local/share/fcitx5/macishtype/engines/<name>/`. That name is the
     engine's identity and must be `[A-Za-z0-9_-]`, or discovery skips it.
     If the engine ships a `setup.py`, run it in the source folder first —
     it puts the generated data tables in place.
3. Open `fcitx5-configtool` → **Input Method** → **Add**, and pick the
   engines from the list — each appears as its own input method. If a newly
   installed folder is not listed, press **Update** in configtool's "Found
   updates" banner: it re-reads the engine folders, no restart needed.

### Upgrade

1. `git pull` and `git submodule update --init --recursive`.
2. `make install` — replaces the installed addon and restarts fcitx5.
3. `make install-engines` when the pinned data tables changed — `make
   install` refreshes `tables/` in the repo, but an installed engine keeps
   the tables it came with.

### Uninstall

`make uninstall` — removes the production install (per cmake's manifest, plus
any preloaded engines) and restarts fcitx5.

User data stays behind, and is yours to remove:

- `~/.local/share/fcitx5/macishtype/engines/` — engine folders, each with
  its own `_storage/`
- `~/.config/fcitx5/conf/macishtype.conf` — addon settings
- `~/.config/fcitx5/macishtype/` — per-engine settings and menu values

Removing a single engine is the same thing: delete its folder.

## Development

### First-time setup

Same flow as [Installation](#installation), but use `make debug` instead of
`make install`: it dev-installs into `~/.local` (no root) and restarts fcitx5
with `FCITX_ADDON_DIRS` pointing there.

The dev install only works while that variable is set, and fcitx5's
autostart won't have it after a re-login. Make it persistent once — adjust
the home path and the system addon directory (`/usr/lib/<multiarch>/fcitx5`
on Debian-family, `/usr/lib64/fcitx5` on RPM-family) to your system:

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
- `make test` — acceptance suite against an isolated fcitx5.
- `make log` — follow the addon's log, scoped to this platform's sources.
- `make log-js` — follow engine `console.*` output only.
- `make log-history` — show recent log history (default 1h;
  `LOG_SHOW_LAST=24h …`).

Engine edits need none of this: engine folders hot-reload on the next
keystroke.

### Other targets

- `make build` — cmake configure + build without installing
  (`BUILD_TYPE=Debug` for an unoptimized build).
- `make prepare` — sync the pinned data tables (incremental; auto-run by
  debug/install).
- `make update-resources` — bump the pinned upstream SHAs to their current
  default-branch HEAD and re-prepare.
- `make dev-install` — install into `~/.local` without restarting fcitx5,
  the install half of `make debug`.
- `make dev-uninstall` — remove that install; engines and settings stay
  (see [First-time setup](#first-time-setup)).
- `make install-engines` — interactive engine installer, copy or symlink
  (see [First install](#first-install)). Out-of-date engines are marked in
  the list; reinstall one to update it. Replacing a copy with a symlink
  discards the copy's `_storage/` (the engine's data), so it asks first.
- `make pkg` — build a native package (`.deb` on Debian-family, `.rpm` on
  RPM-family) with CPack, into `build/`. The version carries a date-and-commit
  stamp (`0.2.0+20260805.93426bb`, `.dirty.<HHMM>` appended for an unclean
  tree so successive local builds stay distinguishable) so an installed
  package points back at the commit it came from; the addon logs the same
  version when it loads. Override `VERSION_STAMP` to change or omit it.
  `PRELOAD_ENGINES` (including `all`) works here too — see
  [First install](#first-install) — and marks the file name with
  `.with-engines`. The package name and version stay
  the same either way, so two packages built from one commit are
  indistinguishable to the package manager — `apt install ./file.deb` sees
  the same version and does nothing, and graphical installers show it as
  already installed; switching between them means removing the installed one
  first. Without the variable the package carries the addon alone and engines
  are installed separately.
- `make restart` — restart fcitx5; `LOG_DEBUG=1` enables per-key Debug
  logging (including engine `console.debug`).
- `make clean` — remove the build directory.
- `make clean-resources` — remove the downloaded data tables and the
  cache/stamp.

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
- Custom manifest `menu` toggles appear after the capability entries in the
  input method's status-area menu (macOS puts them before), with checked
  state shown as a checkbox icon pair like fcitx's own toggles. An item
  whose `disabledWhen` holds hides instead of graying out, dividers are not
  drawn under kimpanel, and values persist under
  `~/.config/fcitx5/macishtype/menu/`.
- The candidate window is fcitx5's own themed one: `layoutDirection`,
  `pageSize`, `indexLabels`, `indexLabelDigitsRequireShift`, and the
  navigation/index-label key options are honored, in the manifest and as
  per-update options alike. `fontSize` and `updateCandidates`' `anchorAt`
  are accepted but have no effect: text size belongs to the fcitx5 theme,
  and window placement is frontend-driven. This host draws none of the
  contract's named windows, so the `candidateWindow.macish` section is
  dropped at load, as are those field names declared at the top level — to
  `manifest.candidateWindow` they are unknown fields, as on every host. A
  digit label that needs Shift is drawn with a `⇧` prefix.
- Associated-word selection keys follow **Addons → MacishType → Associated
  word selection keys**: *Follow engine* (the default) honors the engine's
  `associatedModeIndexLabels` declaration and falls back to number keys,
  while *Number keys* / *Shift + number keys* force the choice for every
  engine. The setting applies to the next activation, not mid-composition.
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

## Known issue: kimpanel on GNOME

The kimpanel Shell extension ([required on GNOME](#runtime)) has a layout
bug: when an engine flips `layoutDirection` per update, the
frame that switches direction renders broken — the panel sits at the wrong
position with a mis-sized backdrop. Tracked upstream as
[gnome-shell-extension-kimpanel#107](https://github.com/wengxt/gnome-shell-extension-kimpanel/issues/107);
until it lands, apply the two-line patch from the issue locally:

1. Edit `~/.local/share/gnome-shell/extensions/kimpanel@kde.org/extension.js`
   as described in the issue.
2. Log out and back in — GNOME Shell only reloads extensions on login.

An extension update from extensions.gnome.org rewrites the file; re-apply
the patch if the broken frame comes back.
