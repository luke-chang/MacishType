// Loadable but never statically imported, so a dynamic import() of it does
// reach the module loader (unlike util.js, which the module map answers).
export const MARKER = "dynamic-import-ok";
