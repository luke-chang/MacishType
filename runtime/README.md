# runtime/

JavaScript sources a platform host evaluates in an engine's context before
the engine's own code. The two files have different audiences:

- [`runtime.js`](runtime.js) — the runtime bootstrap **every** host loads:
  `console`, `TextDecoder`/`TextEncoder`, and the other contract globals
  engines use without importing anything.
- [`hostglue.js`](hostglue.js) — glue for **QuickJS-based hosts only**
  (fcitx5 today; a Windows host would share it). Evaluated before
  `runtime.js`, it defines the bridge globals that are easier to express in
  JS than through the QuickJS C API. JavaScriptCore-based hosts (macOS)
  register those natively.
