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

globalThis.console = {
  log:   (...args) => __MacishType_log("info",   __MacishType_format(args)),
  info:  (...args) => __MacishType_log("info",   __MacishType_format(args)),
  debug: (...args) => __MacishType_log("debug",  __MacishType_format(args)),
  warn:  (...args) => __MacishType_log("notice", __MacishType_format(args)),
  error: (...args) => __MacishType_log("error",  __MacishType_format(args)),
};
