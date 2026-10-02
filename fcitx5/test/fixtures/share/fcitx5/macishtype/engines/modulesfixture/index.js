// Reports what every declared module answers, so the host test can assert the
// injection end to end: which file backs each module, the per-module miss
// value, and the loader's handling of comment / malformed rows. Modules are
// injected before this module evaluates, so reading them at top level is the
// contract's guarantee under test.
const { fontCoverage, symbolNames, wordFrequency } = manifest.modules;

console.log(`modulesfix symbolNames-hit=${symbolNames.query("！")}`);
console.log(`modulesfix symbolNames-miss=${symbolNames.query("＄")}`);
console.log(`modulesfix symbolNames-comment=${symbolNames.query("#＠")}`);
console.log(`modulesfix symbolNames-notab=${symbolNames.query("no-tab-line")}`);
console.log(`modulesfix symbolNames-proto=${symbolNames.query("__proto__")}`);
console.log(`modulesfix wordFrequency-hit=${wordFrequency.query("的")}`);
console.log(`modulesfix wordFrequency-type=${typeof wordFrequency.query("的")}`);
console.log(`modulesfix wordFrequency-miss=${wordFrequency.query("＄")}`);
console.log(`modulesfix wordFrequency-nonnumeric=${wordFrequency.query("bad")}`);
// No file backs fontCoverage (it is computed from installed fonts), so assert
// its shape rather than a value that varies with the system's font set.
console.log(`modulesfix fontCoverage-type=${typeof fontCoverage.query("的")}`);

export default class {
  handleKey() {
    return false;
  }
}
