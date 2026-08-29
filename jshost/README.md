# jshost/ — the shared QuickJS engine host

The QuickJS engine host shared by platform components that embed one: the
engine host (QuickJS runtime, contract bridge globals, fetch pipeline,
localStorage, watchdog), the manifest parser, and the ICU-backed `Intl`
bindings. It is an implementation detail of the embedding JS engine —
nothing else in a platform depends on it. macOS has its own
JavaScriptCore host and does not use it.

## Layout

- [`include/MacishType/`](include/MacishType/) — public headers. The host
  seams are the platform boundary:
  - [`HostSeams.h`](include/MacishType/HostSeams.h) — `Logger`,
    `ResourceLocator`, `PlatformInfo`, `Translator`,
    `FontCoverageProvider`, installed process-wide via `setHostServices()`
  - [`HostEventLoop.h`](include/MacishType/HostEventLoop.h) —
    `HostEventLoop`, injected per engine host at `load()` time
  - [`HostLog.h`](include/MacishType/HostLog.h) — the `MACISHTYPE_*` log
    macro facade over the `Logger` seam
- `src/` — implementation
- [`external/quickjs-ng/`](external/quickjs-ng/) — the JS
  interpreter, pinned as the repo's only git submodule
- [`CMakePresets.json`](CMakePresets.json) — build presets; this directory
  is a standalone CMake project (`cmake --preset linux-release` from
  here), mirroring how each platform directory is self-sufficient

## Consumers

- `fcitx5/` adds this directory with `add_subdirectory` and links
  `macishtype-jshost` into the addon `.so`; its seam implementations live in
  the addon source.
- The headless CLI (this directory) drives the same library for contract
  tests on any platform.

## Threading and error conventions

- Single loop thread: every jshost API and every seam callback runs on the
  embedder's loop thread. The only thread-safe entries are
  `HostEventLoop::post` (marshal onto the loop thread) and, defensively,
  `Logger::write`. The host's one internal worker thread (async fetch) never
  touches the JS context.
- No exceptions across the jshost boundary: failures come back as return
  values (`nullptr` / `std::nullopt` / empty path), `std::filesystem` is
  used through `error_code` overloads, and C++ exceptions never cross a
  QuickJS C stack frame.
- Strings are UTF-8 `std::string` throughout. Host executables on Windows
  should opt into the UTF-8 active code page via their application
  manifest so `std::filesystem::path` round-trips stay lossless.
