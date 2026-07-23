// Exercises the runtime TextDecoder/TextEncoder (WHATWG UTF-8 subset) at
// load time, mirroring the upstream TextCodec test cases. Code points and
// bytes are logged as hex lists so U+FFFD/U+FEFF/NUL stay grep-stable.
const U = (bytes) => new Uint8Array(bytes);
const cps = (s) => [...s].map((c) => c.codePointAt(0).toString(16)).join(",");
const arr = (u8) => Array.from(u8).map((b) => b.toString(16)).join(",");
const errName = (fn) => {
  try { fn(); return "no-throw"; } catch (e) { return e.constructor.name; }
};

// Labels: UTF-8 variants accepted, anything else is a RangeError.
const utf8Labels = ["utf-8", "UTF8", "  utf-8  ", "unicode-1-1-utf-8",
                    "unicode11utf8", "unicode20utf8", "x-unicode20utf8"];
console.log(`labels ${utf8Labels.map((l) => new TextDecoder(l).encoding).join(",")}`);
console.log(`label-default ${new TextDecoder().encoding}`);
console.log(`bad-labels ${["big5", "utf-16", "gbk", "shift_jis", "latin1"]
  .map((l) => errName(() => new TextDecoder(l))).join(",")}`);

// Valid sequences: 1-, 3-, and 4-byte forms, empty inputs.
console.log(`decode-ascii ${new TextDecoder().decode(U([0x41, 0x42]))}`);
console.log(`decode-cjk ${cps(new TextDecoder().decode(U([0xE6, 0xB8, 0xAC])))}`);
console.log(`decode-emoji ${cps(new TextDecoder().decode(U([0xF0, 0x9F, 0x98, 0x80])))}`);
console.log(`decode-noarg-len ${new TextDecoder().decode().length}`);
console.log(`decode-empty-len ${new TextDecoder().decode(U([])).length}`);

// Buffer sources: ArrayBuffer and views honoring byte offset/length.
console.log(`view-buffer ${cps(new TextDecoder().decode(U([0xE6, 0xB8, 0xAC]).buffer))}`);
console.log(`view-subarray ${cps(new TextDecoder().decode(
  U([0, 0, 0xE6, 0xB8, 0xAC, 0]).subarray(2, 5)))}`);
console.log(`view-dataview ${cps(new TextDecoder().decode(
  new DataView(U([0, 0, 0xE6, 0xB8, 0xAC, 0]).buffer, 2, 3)))}`);
console.log(`nonbuffer ${[42, "x", null]
  .map((v) => errName(() => new TextDecoder().decode(v))).join(",")}`);

// Replacement mode: U+FFFD counts follow the WHATWG maximal-subpart rule.
console.log(`replace-lone80 ${cps(new TextDecoder().decode(U([0x80])))}`);
console.log(`replace-trunc ${cps(new TextDecoder().decode(U([0xE4, 0xB8])))}`);
console.log(`replace-overlong ${cps(new TextDecoder().decode(U([0xC0, 0xAF])))}`);
console.log(`replace-f5 ${cps(new TextDecoder().decode(U([0xF5])))}`);
console.log(`replace-surrogate ${cps(new TextDecoder().decode(U([0xED, 0xA0, 0x80])))}`);
console.log(`replace-mid ${cps(new TextDecoder().decode(U([0x41, 0x80, 0x42])))}`);
console.log(`replace-validtail ${cps(new TextDecoder().decode(U([0xE6, 0xB8, 0xAC, 0x41])))}`);

// Fatal mode throws instead of substituting.
console.log(`fatal-invalid ${errName(() =>
  new TextDecoder("utf-8", {fatal: true}).decode(U([0x80])))}`);
console.log(`fatal-trunc ${errName(() =>
  new TextDecoder("utf-8", {fatal: true}).decode(U([0xE4, 0xB8])))}`);
console.log(`fatal-valid ${cps(
  new TextDecoder("utf-8", {fatal: true}).decode(U([0xE6, 0xB8, 0xAC])))}`);

// BOM: stripped once per stream unless ignoreBOM.
console.log(`bom-strip ${cps(new TextDecoder().decode(U([0xEF, 0xBB, 0xBF, 0x41])))}`);
console.log(`bom-only-len ${new TextDecoder().decode(U([0xEF, 0xBB, 0xBF])).length}`);
console.log(`bom-ignore ${cps(new TextDecoder("utf-8", {ignoreBOM: true})
  .decode(U([0xEF, 0xBB, 0xBF, 0x41])))}`);
console.log(`bom-double ${cps(new TextDecoder().decode(
  U([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])))}`);

// Streaming: split sequences complete across chunks; flush handles tails.
{
  const d = new TextDecoder();
  const a = d.decode(U([0xE6, 0xB8]), {stream: true});
  const b = d.decode(U([0xAC]));
  console.log(`stream-split ${cps(a)}|${cps(b)}`);
}
{
  const d = new TextDecoder();
  console.log(`stream-first-len ${d.decode(U([0xE6, 0xB8]), {stream: true}).length}`);
  console.log(`stream-flush ${cps(d.decode())}`);
}
console.log(`stream-fatal ${errName(() => {
  const d = new TextDecoder("utf-8", {fatal: true});
  d.decode(U([0xE4]), {stream: true});
  d.decode();
})}`);
{
  const d = new TextDecoder();
  const a = d.decode(U([0xEF, 0xBB]), {stream: true});
  const b = d.decode(U([0xBF, 0x41]));
  console.log(`stream-bom ${cps(a + b)}`);
}
{
  const d = new TextDecoder();
  d.decode(U([0xE6, 0xB8]));
  console.log(`reset-after-flush ${cps(d.decode(U([0x41])))}`);
}

// TextEncoder.
console.log(`encode-empty-len ${new TextEncoder().encode("").length}`);
console.log(`encode-ascii ${arr(new TextEncoder().encode("A"))}`);
console.log(`encode-cjk ${arr(new TextEncoder().encode("測"))}`);
console.log(`encode-emoji ${arr(new TextEncoder().encode("\u{1F600}"))}`);
console.log(`encode-surrogate ${arr(new TextEncoder().encode("\uD800"))}`);
console.log(`encode-encoding ${new TextEncoder().encoding}`);
console.log(`encode-instance ${new TextEncoder().encode("x") instanceof Uint8Array}`);

const sample = "Hello 測試 \u{1F389} world";
console.log(`roundtrip ${new TextDecoder().decode(new TextEncoder().encode(sample)) === sample}`);

// Embedded NUL: valid mid-string NUL passes; invalid bytes after a NUL are
// still detected (a naive NUL-terminated validator would bless them).
console.log(`nul-valid ${cps(new TextDecoder().decode(U([0x41, 0x00, 0x42])))}`);
console.log(`nul-invalid ${cps(new TextDecoder().decode(U([0x00, 0xFF])))}`);

export default class {};
