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

Not yet implemented: reverse lookup.

Associated mode: committing a single character (when the engine's
`enableAssociatedMode` setting is on and an associated-phrase dictionary is
bundled for its language) holds that character and offers common
follow-ups under a "關聯字" header; picking one commits the pair, any other
key commits the held character alone. The dictionary is derived from the
same pinned corpus as `wordFrequency` (`scripts/external-resources.lock`).

Font coverage (which drives the "displayable" character-set filter) is
computed once when an engine loads; the contract's `fontcoveragechange`
event is not raised for fonts installed mid-session. This is deliberate:
the candidate window is drawn by the desktop (e.g. the kimpanel GNOME
Shell extension), whose own font set only refreshes on re-login under
Wayland, so live-updating the filter alone would surface candidates the
panel still draws as tofu. Installing a font therefore takes effect after
a fcitx5 restart — which the re-login that makes the desktop render the
new font performs anyway, keeping the filter and the renderer in step.

Manifest `settings` become a per-input-method configuration dialog in
`fcitx5-configtool` (select the input method, then the gear button), and
the addon's own options live on its Add-ons page entry. Values persist
under `~/.config/fcitx5/macishtype/<engine>.conf` and reach the live
engine immediately through the contract's `settingschange` event. A field
renders only when its behavior can match the macOS host ("render means
equivalent"); otherwise it stays hidden and its manifest default still
reaches the engine:

- Supported: `toggle`, `textField`, integer `number` (integral default
  and step), `picker` (stored by tag, dropdown only).
- Hidden: `multiSelect`, fractional `number`.
- `system` fields are availability-gated like on macOS: `enableAssociatedMode`
  surfaces only when an associated-phrase dictionary is bundled for the
  engine's language; other or unavailable system fields stay undeclared and
  are not pushed.
- Section titles are ignored (flat list); `disabledWhen`/`hiddenWhen`
  are not evaluated — the rule is rendered as a static sentence in the
  field's tooltip instead.

When the manifest omits `candidateWindow.layoutDirection`, a candidate
orientation setting is generated (Follow system default / Horizontal /
Vertical), matching macOS. "System default" follows the only fcitx global
carrying a candidate direction — classicui's "Vertical Candidate List" —
and falls back to horizontal when it is unreadable (e.g. under kimpanel,
which renders through the desktop rather than classicui). A manifest that
fixes the direction hides the setting.

The macOS General-page keyboard-layout override has a native fcitx5
equivalent: the per-input-method layout (the keyboard button in
configtool's input method list) or the group's default layout.

Engine-private storage (`localStorage`) lives in `_storage/` inside the
engine folder for user-layer engines — matching macOS, the folder stays
self-contained — and under `~/.local/state/fcitx5/macishtype/<engine>/`
for system-layer engines, whose folders are read-only and machine-shared.
External modifications raise the contract's `storage` events (the
engine's own writes stay silent, per web semantics); the watch arms only
while the engine holds storage listeners.

Engines may declare the optional manifest `label` (short panel text;
defaults to the full display name, which fcitx5 shortens per surface — one
CJK glyph or two Latin letters in the status area, the full text in the
input-method switch popup) and `icon` (an extensionless base name inside
the engine folder, default `icon`). The addon probes
`<icon>-symbolic.svg`, `<icon>.svg`, then `<icon>.png` and serves the
first match to panels by absolute path — nothing is installed
into an icon theme. A `-symbolic.svg` gets recolored to the panel
foreground by the desktop; `scripts/generate-icon.py` bakes such a badge
(macOS-style rounded rectangle with the glyph knocked out, carrying both
the GNOME and KDE recoloring conventions) from a glyph. Both fields apply
live on hot reload. Note that `fcitx5-configtool` lists icons by
theme-name lookup only, so path-served icons do not show there.

Engine folders hot-reload:
editing an engine's files (or fixing a broken one) applies on the next
keystroke with a desktop notification, no fcitx5 restart needed — except
display-name changes, which fcitx5 only picks up on restart (its input
method list cannot be updated at runtime). Reloads are scoped to the files
the engine expressed interest in — manifest, entry, imported modules,
fetched data, icon candidates — so unrelated files in the folder don't
trigger one; an engine that failed to load retries on any change. All `manifest.modules` data
sources are fed: wordFrequency and symbolNames from the corpora pinned in
`scripts/external-resources.lock`, fontCoverage from fontconfig.

Traditional→Simplified output is delegated to fcitx5's own chttrans module
(attached automatically for Chinese engines, toggled with its hotkey /
status-area icon, state persisted per input method). The
`outputToSimplified` system menu key proxies the same chttrans state, so
engine-driven toggles and the chttrans hotkey flip one switch.

The contract recommends `Intl.Segmenter` for counting extended grapheme
clusters (so `"👨‍👩‍👧"` or a base plus combining marks counts as one
character). On macOS the engine's JavaScript runtime (JavaScriptCore)
provides it as a standard built-in, but quickjs-ng ships no `Intl` at all,
so the addon supplies `Intl.Segmenter` itself. Only `grapheme` granularity
is implemented — a UAX #29 segmenter over quickjs-ng's Unicode tables,
covering combining marks, astral codepoints, emoji ZWJ sequences, regional-
indicator flags, and conjoining Hangul jamo. `word` and `sentence` throw
`RangeError`: they would need the locale word/sentence dictionaries this
addon deliberately does not bundle, and a naive approximation would diverge
from JavaScriptCore. The Prepend and SpacingMark break classes are folded
into the default class, so clustering can differ from JavaScriptCore for
Arabic and Indic scripts — no bundled engine targets those.

## Development

### Dependencies

Build:

- A C++20 compiler, CMake ≥ 3.16, Ninja, pkg-config
- Fcitx5 development files: the `Fcitx5Core` CMake package plus the
  Notifications module headers, matching your installed fcitx5 (this addon
  is developed against 5.1.x)
- fontconfig development files
- git — quickjs-ng is a submodule; clone with `--recurse-submodules`
- gettext

Data preparation (`make prepare`): `curl`, `python3`.

Icon badge generation (`scripts/generate-icon.py`, optional authoring
tool): `python3` with fontTools (`python3-fonttools` on Debian-family) and
fontconfig's `fc-match`.

Tests (`make test`): `python3` with GObject introspection (`python3-gi` on
Debian-family), `dbus-run-session`, and an installed fcitx5 to test
against.

On Debian/Ubuntu, everything above is:

```sh
sudo apt install build-essential cmake ninja-build pkgconf git \
    fcitx5-modules-dev libfcitx5core-dev libfontconfig-dev \
    gettext curl python3 python3-gi python3-fonttools dbus
```

### Workflow

```sh
make build     # cmake configure + build
make prepare   # sync pinned module data tables (also run by debug/install)
make debug     # dev install into ~/.local + fcitx5 restart (interrupts typing)
make test      # acceptance suite against an isolated fcitx5
make install   # production install into /usr (sudo) + fcitx5 restart
make uninstall # remove the production install (per cmake's manifest)

make log          # follow the addon's log (scoped to this repo's sources)
make log-js       # follow engine console.* output only
make log-history  # show recent addon log (default 1h; LOG_SHOW_LAST=24h ...)
```

fcitx5 logs to the user journal regardless of how it was started
(session autostart or `make restart`). Per-key Debug logging — including
engine `console.debug` — is off by default; restart with
`make restart LOG_DEBUG=1` (or `make debug LOG_DEBUG=1`) to enable it.

```sh
```

### Dev install and `FCITX_ADDON_DIRS`

fcitx5 only searches its baked-in system directory for addon `.so` files,
so the dev install relies on launching fcitx5 with `FCITX_ADDON_DIRS`
(`make restart` does this for the current session). Make it survive
re-login with a one-time systemd user-environment entry — adjust the home
path and the multiarch triplet (`gcc -dumpmachine`) to your system:

```sh
cat > ~/.config/environment.d/90-fcitx5-macishtype.conf <<'EOF'
FCITX_ADDON_DIRS=/home/YOU/.local/lib/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5
EOF
```

Notes:

- The variable REPLACES the default search path; keep the system directory
  listed or every other addon breaks.
- `environment.d` is read at login, so the entry takes effect on the next
  login; use `make restart` to apply immediately.
- **Skipping this bites after the next re-login**: the autostarted fcitx5
  comes up without the variable, fails to load the addon, and prunes its
  input methods from `~/.config/fcitx5/profile` on save — they have to be
  re-added in fcitx5-configtool.
- A production `make install` needs none of this (and run
  `make dev-uninstall` first — user-dir files shadow the system install).

## License

MIT, same as MacishType. `runtime.js` is copied from the MacishType
repository; its provenance commit is recorded in the file header.
