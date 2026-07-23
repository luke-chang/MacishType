#!/bin/sh
# TextDecoder/TextEncoder from runtime.js (WHATWG UTF-8 subset), mirroring
# the upstream TextCodec test cases. textcodecfixture logs hex code-point /
# byte lists at load; U+FFFD is "fffd", U+FEFF "feff".
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-textcodec.log
ISOLATED_LOG="$log" "$root/test/isolated.sh" textcodecfixture > /dev/null 2>&1
out="$(cat "$log")"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

check "UTF-8 labels are accepted" "$out" \
    'labels utf-8,utf-8,utf-8,utf-8,utf-8,utf-8,utf-8'
check "the default label is utf-8" "$out" \
    'label-default utf-8'
check "non-UTF-8 labels throw RangeError" "$out" \
    'bad-labels RangeError,RangeError,RangeError,RangeError,RangeError'
check "ASCII decodes" "$out" \
    'decode-ascii AB'
check "a 3-byte sequence decodes" "$out" \
    'decode-cjk 6e2c'
check "a 4-byte sequence decodes" "$out" \
    'decode-emoji 1f600'
check "decode without input yields the empty string" "$out" \
    'decode-noarg-len 0'
check "an empty buffer decodes to the empty string" "$out" \
    'decode-empty-len 0'
check "an ArrayBuffer is accepted" "$out" \
    'view-buffer 6e2c'
check "a subarray honors its byte offset" "$out" \
    'view-subarray 6e2c'
check "a DataView honors its byte offset" "$out" \
    'view-dataview 6e2c'
check "non-buffer inputs throw TypeError" "$out" \
    'nonbuffer TypeError,TypeError,TypeError'
check "a lone continuation byte becomes one U+FFFD" "$out" \
    'replace-lone80 fffd'
check "a truncated sequence becomes one U+FFFD" "$out" \
    'replace-trunc fffd'
check "an overlong encoding becomes two U+FFFD" "$out" \
    'replace-overlong fffd,fffd'
check "an out-of-range lead byte becomes one U+FFFD" "$out" \
    'replace-f5 fffd'
check "an encoded surrogate becomes three U+FFFD" "$out" \
    'replace-surrogate fffd,fffd,fffd'
check "an invalid byte does not swallow its neighbors" "$out" \
    'replace-mid 41,fffd,42'
check "a valid tail after a sequence is kept" "$out" \
    'replace-validtail 6e2c,41'
check "fatal throws on an invalid byte" "$out" \
    'fatal-invalid TypeError'
check "fatal throws on a truncated sequence" "$out" \
    'fatal-trunc TypeError'
check "fatal decodes valid input" "$out" \
    'fatal-valid 6e2c'
check "a leading BOM is stripped" "$out" \
    'bom-strip 41'
check "a bare BOM decodes to the empty string" "$out" \
    'bom-only-len 0'
check "ignoreBOM keeps the BOM" "$out" \
    'bom-ignore feff,41'
check "a second BOM is preserved" "$out" \
    'bom-double feff'
check "a sequence split across chunks completes" "$out" \
    'stream-split |6e2c'
check "a streaming chunk holds an incomplete tail" "$out" \
    'stream-first-len 0'
check "flush emits U+FFFD for the held tail" "$out" \
    'stream-flush fffd'
check "fatal streaming throws on flush" "$out" \
    'stream-fatal TypeError'
check "a BOM split across chunks is still stripped" "$out" \
    'stream-bom 41'
check "a non-streaming call resets decoder state" "$out" \
    'reset-after-flush 41'
check "encoding the empty string yields no bytes" "$out" \
    'encode-empty-len 0'
check "ASCII encodes" "$out" \
    'encode-ascii 41'
check "a 3-byte character encodes" "$out" \
    'encode-cjk e6,b8,ac'
check "a 4-byte character encodes" "$out" \
    'encode-emoji f0,9f,98,80'
check "a lone surrogate encodes to U+FFFD" "$out" \
    'encode-surrogate ef,bf,bd'
check "the encoder reports utf-8" "$out" \
    'encode-encoding utf-8'
check "encode returns a Uint8Array" "$out" \
    'encode-instance true'
check "decode(encode(s)) round-trips" "$out" \
    'roundtrip true'
check "an embedded NUL decodes in place" "$out" \
    'nul-valid 41,0,42'
check "invalid bytes after a NUL are still replaced" "$out" \
    'nul-invalid 0,fffd'
check "the native decode fast path engaged" "$out" \
    'decodeUTF8: native fast path'
check "the native decode declined invalid input" "$out" \
    'decodeUTF8: declined'
check "the native encode fast path engaged" "$out" \
    'encodeUTF8: native fast path'
echo "TextDecoder/TextEncoder checks passed."
