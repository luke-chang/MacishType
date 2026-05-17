// Global APIs for JavaScript engines, auto-evaluated by the bridge before
// engine code so engines use these without importing anything.
//
// Currently: console.{log,info,debug,warn,error} → Swift OSLog.
// Future: file I/O, etc.
//
// JS console levels → OSLog:
//   log/info → .info       warn  → .notice
//   debug    → .debug      error → .error
// .fault is reserved for the bridge itself; engines reach it only via
// __MacishType_log("fault", ...), not part of the public API.

function __MacishType_format(args) {
  return args.map((value) => {
    if (typeof value === "string") return value;
    if (typeof value === "object" && value !== null) {
      try { return JSON.stringify(value); } catch { return String(value); }
    }
    return String(value);
  }).join(" ");
}

// Drop frames originating from this runtime so the reported first line is
// the engine-side caller, not the console wrapper plumbing.
function __MacishType_callerStack() {
  const stack = new Error().stack;
  if (!stack) return "";
  return stack.split("\n").filter((line) => !line.includes("runtime.js")).join("\n");
}

globalThis.console = {
  log:   (...args) => __MacishType_log("info",   __MacishType_format(args)),
  info:  (...args) => __MacishType_log("info",   __MacishType_format(args)),
  debug: (...args) => __MacishType_log("debug",  __MacishType_format(args)),
  warn:  (...args) => __MacishType_log("notice", __MacishType_format(args) + "\n" + __MacishType_callerStack()),
  error: (...args) => __MacishType_log("error",  __MacishType_format(args) + "\n" + __MacishType_callerStack()),
  trace: (...args) => __MacishType_log("info",   __MacishType_format(args) + "\n" + __MacishType_callerStack()),
};

(function () {
  const listeners = new Map();
  // Stable reference: same object across updates so engines can destructure
  // `const { settings } = manifest` and keep using `settings`. Content is
  // replaced in-place; engines must treat it as read-only (no runtime
  // freeze — that would prevent the in-place update).
  const settings = {};

  function dispatch(type) {
    const cbs = listeners.get(type);
    if (!cbs) return;
    const event = { type };
    for (const cb of cbs) {
      try { cb(event); }
      catch (e) {
        // Error own properties are non-enumerable, so JSON.stringify(e)
        // collapses to "{}" — reach into .stack for a meaningful log.
        console.error("settingschange listener threw:", e?.stack ?? String(e));
      }
    }
  }

  // Shallow read-only Proxy: top-level writes throw, reads forward to
  // the internal `settings` object. Nested objects/arrays aren't frozen
  // (deep mutation possible but pointless — next host push clobbers).
  const settingsProxy = new Proxy({}, {
    get(_, prop, recv) { return Reflect.get(settings, prop, recv); },
    has(_, prop) { return Reflect.has(settings, prop); },
    ownKeys() { return Reflect.ownKeys(settings); },
    getOwnPropertyDescriptor(_, prop) {
      if (!(prop in settings)) return undefined;
      return {
        value: settings[prop],
        writable: false,
        enumerable: true,
        configurable: true,
      };
    },
    set() { throw new TypeError("manifest.settings is read-only"); },
    deleteProperty() { throw new TypeError("manifest.settings is read-only"); },
    defineProperty() { throw new TypeError("manifest.settings is read-only"); },
  });

  globalThis.manifest = {
    get settings() { return settingsProxy; },
    addEventListener(type, callback) {
      if (typeof callback !== "function") return;
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(callback);
    },
    removeEventListener(type, callback) {
      listeners.get(type)?.delete(callback);
    },
  };

  // manifest.candidateWindow — Proxy-backed cache the engine can read/write.
  // Source of truth lives in Swift; this object forwards all access through
  // bridge calls. Writes that fail (read-only field, unknown name, invalid
  // value) are warned via OSLog on the Swift side and silently ignored —
  // the set trap always returns true so engine code never sees an exception.
  const candidateWindowProxy = new Proxy({}, {
    get(_, prop) {
      if (typeof prop !== "string") return undefined;
      const value = __MacishType_getCandidateWindowField(prop);
      return value === null ? undefined : value;
    },
    set(_, prop, value) {
      if (typeof prop === "string") {
        __MacishType_setCandidateWindowField(prop, value);
      }
      return true;
    },
    has(_, prop) {
      if (typeof prop !== "string") return false;
      return __MacishType_getCandidateWindowField(prop) !== null;
    },
    ownKeys() {
      return __MacishType_candidateWindowFields();
    },
    getOwnPropertyDescriptor(_, prop) {
      if (typeof prop !== "string") return undefined;
      const value = __MacishType_getCandidateWindowField(prop);
      if (value === null) return undefined;
      return { value, writable: true, enumerable: true, configurable: true };
    },
  });
  Object.defineProperty(globalThis.manifest, "candidateWindow", {
    get() { return candidateWindowProxy; },
    enumerable: true,
    configurable: false,
  });

  function deepFreeze(v) {
    if (v === null || typeof v !== "object" || Object.isFrozen(v)) return v;
    for (const k of Object.keys(v)) deepFreeze(v[k]);
    return Object.freeze(v);
  }

  // Private updater — Swift bridge entrypoint. The Swift side gates pushes
  // on actual change, so this unconditionally replaces and dispatches.
  globalThis.__MacishType_setSettings = function (next) {
    for (const k of Object.keys(settings)) delete settings[k];
    Object.assign(settings, next);
    // Top-level stays mutable for the next push's clear+assign; the Proxy
    // blocks engine top-level writes. Freeze nested values so engine
    // can't mutate them either — full deep read-only as seen by JS.
    for (const k of Object.keys(settings)) deepFreeze(settings[k]);
    dispatch("settingschange");
  };
})();

// localStorage — file-backed via Swift bridges. Reads are cached for
// the current sync task (microtask-bounded) so iteration / repeated
// reads only hit Swift once; mutations invalidate immediately.
(function () {
  let cachedKeys = null;
  const cachedValues = new Map();
  let invalidationScheduled = false;

  // Promise microtask drains when the host call's JS stack empties,
  // giving per-handleKey cache lifetime. queueMicrotask isn't in pure
  // JSC (no WebCore globals); Promise.resolve().then is ECMAScript.
  function scheduleInvalidate() {
    if (invalidationScheduled) return;
    invalidationScheduled = true;
    Promise.resolve().then(() => {
      cachedKeys = null;
      cachedValues.clear();
      invalidationScheduled = false;
    });
  }
  function invalidateNow() {
    cachedKeys = null;
    cachedValues.clear();
  }

  const localStorage = {
    get length() {
      if (cachedKeys === null) {
        cachedKeys = __MacishType_storageKeys();
        scheduleInvalidate();
      }
      return cachedKeys.length;
    },
    key(index) {
      const i = Number(index);
      if (!Number.isFinite(i) || i < 0) return null;
      if (cachedKeys === null) {
        cachedKeys = __MacishType_storageKeys();
        scheduleInvalidate();
      }
      const idx = Math.floor(i);
      return idx < cachedKeys.length ? cachedKeys[idx] : null;
    },
    getItem(key) {
      const k = String(key);
      if (cachedValues.has(k)) return cachedValues.get(k);
      const value = __MacishType_storageGetItem(k);
      cachedValues.set(k, value);
      scheduleInvalidate();
      return value;
    },
    setItem(key, value) {
      __MacishType_storageSetItem(String(key), String(value));
      invalidateNow();
    },
    removeItem(key) {
      __MacishType_storageRemoveItem(String(key));
      invalidateNow();
    },
    clear() {
      __MacishType_storageClear();
      invalidateNow();
    },
  };

  Object.defineProperty(globalThis, "localStorage", {
    value: Object.freeze(localStorage),
    writable: false,
    enumerable: true,
    configurable: false,
  });
})();
