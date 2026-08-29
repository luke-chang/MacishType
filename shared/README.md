# shared/ — the platform-independent library

What every MacishType host needs regardless of whether it embeds a JS
engine: the log facade, the ICU handle cache behind grapheme segmentation,
UTF-8 validation, and the associated-phrase dictionary.

## What belongs here

The criterion is the **consumer set**: something belongs here when more
than one host needs it and it is not tied to a particular JS runtime.
Anything that only a QuickJS host can use — the bridge globals, the Intl
natives, the manifest parser — stays in [`jshost/`](../jshost/).

## Layout

- [`include/MacishType/`](include/MacishType/) — public headers, exported
  under the same `MacishType/` prefix `jshost/` uses, so a consumer sees
  one coherent header namespace across both libraries
- `src/` — implementation
- `js/` — shared JavaScript assets loaded by every host

## Consumers

- `jshost/` links it `PUBLIC`, so the fcitx5 addon gets it transitively.
- A host whose engines are native links it directly and never pulls in
  QuickJS. Keeping that possible is why this library exists, so the
  acceptance check is that `libmacishtype-shared.a` plus ICU links a
  program on its own — the contract tests cannot catch a regression here,
  because the addon folds both libraries into one `.so`.

## Conventions

- Single loop thread, same as `jshost/`: callers invoke these APIs from
  their own loop thread. `Logger::write` should still be thread-safe as
  defense in depth.
- No exceptions across the library boundary: failures come back as return
  values (`nullptr` / `std::nullopt` / empty containers).
- Strings are UTF-8 `std::string` throughout.
