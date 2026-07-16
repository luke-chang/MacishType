# Array (行列) — JavaScript engine

A JavaScript port of MacishType's bundled Swift Array (行列) engine. It tracks
the Swift engine feature-for-feature and exists to exercise the JS engine API
end to end.

## Setup

1. **Sync the data tables.**

   ```sh
   ./setup.sh
   ```

   This copies the processed Array tables out of the repo's build resources into
   this folder. The tables are produced by `make prepare`; if they're missing,
   the script runs `make prepare` first. The copied `*.txt` files are generated
   artifacts and are gitignored — re-run the script after a `make prepare` or a
   resource-lock bump.

2. **Load the engine.** In MacishType, open **Settings → JS → Engine folder →
   Choose Folder…** and pick this folder. The host watches the folder and
   hot-reloads on edit, so iterating doesn't require restarting the input
   method.

## Features

Mirrors the Swift engine:

- **Short codes** for 1–2 key codes (一/二級簡碼), with fixed selection keys.
- **Paging** through any candidate list with `=` / `]` / `Shift+→` (forward)
  and `-` / `[` / `Shift+←` (back).
- **Phrases** — end the code with `'` (instead of Space) to look up phrases.
- **Wildcards** with `?` (one radical) and `*` (one or more); a leading `*`
  matches any code containing the given radicals in any order.
- **Symbol groups** via `w` / `hg` + digit, shown as a group menu and then a
  named symbol list.
- **Full-width** punctuation via Option + key.
- **Character set** picker in Settings (standard / all displayable / full) that
  filters candidates by installed-font coverage.
- **Reverse lookup** (`capabilities.reverseLookup`) for the host's Find Input
  Code window: main codes as radical readouts, then short codes as
  `readout+selectionKey` annotated 簡碼.

## Tests

Run the suite with Node's built-in test runner (no dependencies); it stubs the
host globals and drives the engine against the real data tables, so run
`./setup.sh` first.

```sh
node --test Engines/ArrayEngine/index.test.mjs
```
