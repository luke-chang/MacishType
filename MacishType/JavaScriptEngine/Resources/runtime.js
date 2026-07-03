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

// Only `once` is supported; other Web-spec keys warn and are ignored.
function __MacishType_parseListenerOptions(options) {
  if (options === undefined) return { once: false };
  if (!options || typeof options !== "object") {
    console.warn("addEventListener: only object options are supported");
    return { once: false };
  }
  for (const k of Object.keys(options)) {
    if (k !== "once") {
      console.warn(`addEventListener: option '${k}' is ignored`);
    }
  }
  return { once: !!options.once };
}

// Spec: `handleEvent` is read at dispatch time (engines may reassign
// after registration) and a non-callable value is a silent no-op.
function __MacishType_invokeListener(cb, event) {
  if (typeof cb === "function") { cb(event); return; }
  const fn = cb.handleEvent;
  if (typeof fn === "function") fn.call(cb, event);
}

// Snapshot before iterating so add/remove during a callback matches the
// listener-list-at-dispatch-time semantics. `label` shows up in the
// per-listener error log to identify which event type threw.
function __MacishType_dispatchListeners(listeners, event, label) {
  for (const cb of [...listeners]) {
    try { __MacishType_invokeListener(cb, event); }
    catch (e) {
      console.error(`${label} listener threw:`, e?.stack ?? String(e));
    }
  }
}

// Generic globalThis event registry. onceWrappers is per-type so the
// same callback registered with `{ once: true }` to multiple types
// gets distinct wrappers. Hooks let event owners react to 0↔1
// listener-count transitions (e.g. storage's lazy FSEvent watcher).
const __MacishType_globalListeners = new Map();
const __MacishType_globalOnceWrappers = new Map();  // type → WeakMap<cb, wrapper>
const __MacishType_globalListenerHooks = new Map();

function __MacishType_onceWrappersForType(type) {
  let m = __MacishType_globalOnceWrappers.get(type);
  if (!m) {
    m = new WeakMap();
    __MacishType_globalOnceWrappers.set(type, m);
  }
  return m;
}

globalThis.addEventListener = function (type, callback, options) {
  const isFunction = typeof callback === "function";
  const isObject = !isFunction && callback !== null && typeof callback === "object";
  if (!isFunction && !isObject) return;
  // Catch the common typo (handelEvent / forgot to assign) early. Still
  // registered, since spec allows assigning handleEvent after the fact.
  if (isObject && typeof callback.handleEvent !== "function") {
    console.warn(`addEventListener('${type}'): listener object has no callable handleEvent (typo?)`);
  }
  // Spec: re-registering the same (type, callback) is a no-op, whatever
  // the options.
  if (__MacishType_globalListeners.get(type)?.has(callback)
      || __MacishType_globalOnceWrappers.get(type)?.has(callback)) return;
  const { once } = __MacishType_parseListenerOptions(options);
  let effective = callback;
  if (once) {
    const wrappers = __MacishType_onceWrappersForType(type);
    effective = function (event) {
      const set = __MacishType_globalListeners.get(type);
      wrappers.delete(callback);
      if (set?.delete(effective) && set.size === 0) {
        __MacishType_globalListenerHooks.get(type)?.(false);
      }
      __MacishType_invokeListener(callback, event);
    };
    wrappers.set(callback, effective);
  }
  if (!__MacishType_globalListeners.has(type)) {
    __MacishType_globalListeners.set(type, new Set());
  }
  const set = __MacishType_globalListeners.get(type);
  const wasEmpty = set.size === 0;
  set.add(effective);
  if (wasEmpty) __MacishType_globalListenerHooks.get(type)?.(true);
};

globalThis.removeEventListener = function (type, callback) {
  const set = __MacishType_globalListeners.get(type);
  if (!set) return;
  const wrappers = __MacishType_globalOnceWrappers.get(type);
  const target = wrappers?.get(callback) ?? callback;
  wrappers?.delete(callback);
  const had = set.delete(target);
  if (had && set.size === 0) {
    __MacishType_globalListenerHooks.get(type)?.(false);
  }
};

function __MacishType_dispatchGlobal(event) {
  const set = __MacishType_globalListeners.get(event.type);
  if (!set) return;
  __MacishType_dispatchListeners(set, event, event.type);
}

(function () {
  // Stable reference: same object across updates so engines can destructure
  // `const { settings } = manifest` and keep using `settings`. Content is
  // replaced in-place; engines must treat it as read-only (no runtime
  // freeze — that would prevent the in-place update).
  const settings = {};

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

  // Host-injected data tables, populated by __MacishType_setModuleData before
  // engine code runs. Stable container so engines can destructure
  // `const { ... } = manifest.modules`; engines treat it as read-only (the
  // injected values are frozen, the container itself is left plain).
  const modules = {};

  globalThis.manifest = {
    // null (name absent) → undefined, mirroring candidateWindow below.
    get name() {
      const value = __MacishType_manifestName();
      return value === null ? undefined : value;
    },
    get settings() { return settingsProxy; },
    get modules() { return modules; },
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
    __MacishType_dispatchGlobal({ type: "settingschange" });
  };

  // Private updater — Swift bridge entrypoint. `data` is a plain object the
  // host built from a whole table; `miss` is the value query() returns for an
  // absent key (host-chosen per table, e.g. undefined for names, 0 for
  // counts). The frozen facade is what makes it read-only — a raw Map can't be
  // meaningfully frozen (Object.freeze leaves set/delete working). `has`
  // distinguishes a stored falsy value from a genuine miss.
  globalThis.__MacishType_setModuleData = function (name, data, miss) {
    const inner = new Map(Object.entries(data));
    modules[name] = Object.freeze({
      query: (key) => (inner.has(key) ? inner.get(key) : miss),
    });
  };

  // Base64 → Uint8Array. Pure JSC has no atob, so decode by hand. Skips any
  // non-alphabet byte (whitespace/newlines) and ignores '=' padding.
  const B64_CHARS =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const B64_LOOKUP = (() => {
    const table = new Int16Array(128).fill(-1);
    for (let i = 0; i < B64_CHARS.length; i++) table[B64_CHARS.charCodeAt(i)] = i;
    return table;
  })();
  function decodeBase64(b64) {
    let len = b64.length;
    while (len > 0 && b64[len - 1] === "=") len--;
    const out = new Uint8Array((len * 3) >> 2);
    let acc = 0, bits = 0, oi = 0;
    for (let i = 0; i < len; i++) {
      const code = b64.charCodeAt(i);
      const value = code < 128 ? B64_LOOKUP[code] : -1;
      if (value < 0) continue;
      acc = (acc << 6) | value;
      bits += 6;
      if (bits >= 8) { bits -= 8; out[oi++] = (acc >> bits) & 0xff; }
    }
    return out;
  }

  // Parse a base64 CharacterSet bitmap into plane number → 8192-byte slice.
  // bitmapRepresentation: plane 0 = first 8192 bytes; then each non-empty plane
  // is 1 byte plane-number + 8192 bytes. Scalar n present iff byte (n>>3) bit
  // (n&7) is set (LSB-first). NOTE: assumes the first 8192 bytes are plane 0 —
  // always true for a font-coverage union (BMP is never empty), but NOT a
  // general CharacterSet invariant; don't reuse this as a generic decoder.
  function parseCoverageBitmap(base64) {
    const bytes = decodeBase64(base64);
    const planes = new Map();
    planes.set(0, bytes.subarray(0, 8192));
    let offset = 8192;
    while (offset < bytes.length) {
      planes.set(bytes[offset], bytes.subarray(offset + 1, offset + 1 + 8192));
      offset += 1 + 8192;
    }
    return planes;
  }

  // Backing store per coverage module, swappable in place so the frozen view's
  // identity stays stable across updates (engines may destructure it once).
  const coverageHolders = new Map();   // name -> { planes }

  // Swift bridge entrypoint — build the holder-backed query view at load.
  globalThis.__MacishType_setCoverageModule = function (name, base64) {
    const holder = { planes: parseCoverageBitmap(base64) };
    coverageHolders.set(name, holder);
    const covers = (codePoint) => {
      const plane = holder.planes.get(codePoint >> 16);
      if (!plane) return false;
      const within = codePoint & 0xffff;
      return (plane[within >> 3] & (1 << (within & 7))) !== 0;
    };
    modules[name] = Object.freeze({
      query(value) {
        for (const ch of value) if (!covers(ch.codePointAt(0))) return false;
        return true;
      },
    });
  };

  // Swift bridge — swap the holder's bitmap, then notify. The host only calls
  // this on a real change, so no JS-side compare. No-op if never injected.
  globalThis.__MacishType_updateCoverageModule = function (name, base64) {
    const holder = coverageHolders.get(name);
    if (!holder) return;
    holder.planes = parseCoverageBitmap(base64);
    __MacishType_dispatchGlobal({ type: "fontcoveragechange" });
  };
})();

// localStorage + storage events — shared closure so dispatch can
// reach invalidateNow without exposing it. Reads are cached for the
// current sync task (microtask-bounded) so iteration / repeated
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

  // --- storage events ---

  __MacishType_globalListenerHooks.set("storage", (active) => {
    __MacishType_setStorageListening(active);
  });

  globalThis.__MacishType_dispatchStorageEvent = function (key) {
    const set = __MacishType_globalListeners.get("storage");
    if (!set || set.size === 0) return;
    // External mod just landed → cache must not return stale value
    // to listeners. The microtask of the previous JS task should
    // already have drained the cache, but explicit invalidation
    // removes any dependency on JSC drain timing.
    invalidateNow();

    const event = {
      type: "storage",
      key,
      oldValue: null,
      storageArea: localStorage,
    };
    // Lazy: read disk only when a listener actually touches
    // newValue, then freeze via property redefinition so further
    // accesses don't re-read.
    Object.defineProperty(event, "newValue", {
      get() {
        const value = localStorage.getItem(key);
        Object.defineProperty(event, "newValue", {
          value, enumerable: true, configurable: true, writable: false,
        });
        return value;
      },
      enumerable: true,
      configurable: true,
    });

    __MacishType_dispatchGlobal(event);
  };
})();

// navigator — Web-aligned host info + locale preferences. languages
// can change at runtime via NSLocale notification; userAgent is static.
(function () {
  let cachedLanguages = Object.freeze(__MacishType_getLanguages());
  const userAgent = __MacishType_userAgent;

  function sameArray(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  const navigator = {};
  Object.defineProperties(navigator, {
    language: { get() { return cachedLanguages[0] ?? ""; }, enumerable: true },
    languages: { get() { return cachedLanguages; }, enumerable: true },
    userAgent: { value: userAgent, enumerable: true, writable: false },
  });

  Object.defineProperty(globalThis, "navigator", {
    value: Object.freeze(navigator),
    writable: false,
    enumerable: true,
    configurable: false,
  });

  globalThis.__MacishType_dispatchLanguageChange = function () {
    // NSLocale notification fires on many locale changes (calendar /
    // currency / numbering system) — not just languages. Dedup
    // before freezing so spurious notifications don't even allocate.
    const next = __MacishType_getLanguages();
    if (sameArray(cachedLanguages, next)) return;
    cachedLanguages = Object.freeze(next);
    __MacishType_dispatchGlobal({ type: "languagechange" });
  };
})();

// fetch — minimal subset for reading files from the engine folder.
// Path must start with "./". Only Response.text/json/arrayBuffer are
// implemented; no headers, method, body, streams, abort signal, etc.
globalThis.fetch = function (input, init) {
  if (typeof input !== "string") {
    return Promise.reject(new TypeError(
      "fetch: input must be a string (got " + typeof input + ")"));
  }
  if (init !== undefined) {
    console.warn("fetch: init argument is ignored");
  }
  return new Promise((resolve, reject) => {
    __MacishType_fetch(input, resolve, reject);
  });
};
