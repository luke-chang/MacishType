// Differential test for the strict UTF-8 validator against ICU. The function
// defines the WHATWG UTF-8 behavior engines observe -- through TextDecoder,
// the associated dictionary's query guard, and the grapheme index -- so a
// corner where it disagrees with ICU is a cross-platform inconsistency an
// engine author would hit before we did.

#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <string_view>

#include <unicode/utf8.h>

#include "Checks.h"
#include "MacishType/Utf8.h"

namespace {

using MacishType::isStrictUtf8;

// U8_NEXT reports an ill-formed sequence as a negative code point, so a
// buffer is well-formed only when every sequence in it decodes.
bool icuAccepts(const uint8_t *data, size_t size) {
    int32_t index = 0;
    auto length = static_cast<int32_t>(size);
    while (index < length) {
        UChar32 code;
        U8_NEXT(data, index, length, code);
        if (code < 0) {
            return false;
        }
    }
    return true;
}

std::string toHex(const uint8_t *data, size_t size) {
    static const char digits[] = "0123456789ABCDEF";
    std::string hex;
    for (size_t i = 0; i < size; i++) {
        if (i != 0) {
            hex += ' ';
        }
        hex += digits[data[i] >> 4];
        hex += digits[data[i] & 0x0F];
    }
    return hex;
}

// Counts every disagreement but keeps only the first sequence: a systematic
// difference would otherwise bury the interesting case in output.
struct Differential {
    long disagreements = 0;
    std::string first;

    void compare(const uint8_t *data, size_t size) {
        if (isStrictUtf8(data, size) == icuAccepts(data, size)) {
            return;
        }
        if (disagreements == 0) {
            first = toHex(data, size);
        }
        ++disagreements;
    }

    void report(Checks &checks, const char *what) const {
        std::string message(what);
        if (disagreements != 0) {
            message += " (" + std::to_string(disagreements) +
                       " disagreements, first " + first + ")";
        }
        checks.expect(disagreements == 0, message.c_str());
    }
};

void exhaustive(Checks &checks) {
    uint8_t buffer[3];
    Differential one;
    for (int a = 0; a < 256; a++) {
        buffer[0] = static_cast<uint8_t>(a);
        one.compare(buffer, 1);
    }
    one.report(checks, "every 1-byte sequence matches ICU");

    Differential two;
    for (int a = 0; a < 256; a++) {
        buffer[0] = static_cast<uint8_t>(a);
        for (int b = 0; b < 256; b++) {
            buffer[1] = static_cast<uint8_t>(b);
            two.compare(buffer, 2);
        }
    }
    two.report(checks, "every 2-byte sequence matches ICU");

    Differential three;
    for (int a = 0; a < 256; a++) {
        buffer[0] = static_cast<uint8_t>(a);
        for (int b = 0; b < 256; b++) {
            buffer[1] = static_cast<uint8_t>(b);
            for (int c = 0; c < 256; c++) {
                buffer[2] = static_cast<uint8_t>(c);
                three.compare(buffer, 3);
            }
        }
    }
    three.report(checks, "every 3-byte sequence matches ICU");
}

void fourByte(Checks &checks) {
    // Well-formed four-byte sequences are a vanishing fraction of the 4 GB
    // space, so random sampling alone would only ever exercise rejection.
    Differential encoded;
    uint8_t buffer[4];
    for (UChar32 code = 0x10000; code <= 0x10FFFF; code++) {
        buffer[0] = static_cast<uint8_t>(0xF0 | (code >> 18));
        buffer[1] = static_cast<uint8_t>(0x80 | ((code >> 12) & 0x3F));
        buffer[2] = static_cast<uint8_t>(0x80 | ((code >> 6) & 0x3F));
        buffer[3] = static_cast<uint8_t>(0x80 | (code & 0x3F));
        encoded.compare(buffer, 4);
    }
    encoded.report(checks, "every 4-byte code point matches ICU");

    // Lead byte in full against the values where the strict ranges change:
    // overlong floors, the surrogate and U+10FFFF ceilings, continuation
    // edges, and the bytes that are never a lead.
    static const uint8_t kEdges[] = {
        0x00, 0x01, 0x7F, 0x80, 0x81, 0x8F, 0x90, 0x91, 0x9F, 0xA0, 0xA1,
        0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xED, 0xEE, 0xEF, 0xF0,
        0xF1, 0xF4, 0xF5, 0xFF,
    };
    Differential edges;
    for (int lead = 0; lead < 256; lead++) {
        buffer[0] = static_cast<uint8_t>(lead);
        for (uint8_t second : kEdges) {
            buffer[1] = second;
            for (uint8_t third : kEdges) {
                buffer[2] = third;
                for (uint8_t fourth : kEdges) {
                    buffer[3] = fourth;
                    edges.compare(buffer, 4);
                }
            }
        }
    }
    edges.report(checks, "4-byte sequences over the range edges match ICU");

    // Fixed seed so a failure reproduces exactly.
    Differential sampled;
    std::mt19937 rng(20260918);
    std::uniform_int_distribution<int> anyByte(0, 255);
    for (int i = 0; i < 2000000; i++) {
        for (uint8_t &slot : buffer) {
            slot = static_cast<uint8_t>(anyByte(rng));
        }
        sampled.compare(buffer, 4);
    }
    sampled.report(checks, "sampled 4-byte sequences match ICU");
}

} // namespace

void testUtf8Validation(Checks &checks) {
    exhaustive(checks);
    fourByte(checks);

    // Named cases pinning what "strict" means on its own terms, so the
    // contract stays readable here even if the ICU comparison is retired.
    checks.expect(isStrictUtf8(std::string_view()), "empty input is valid");
    checks.expect(isStrictUtf8(std::string_view("a\0b", 3)),
                  "an embedded NUL is an ordinary byte");
    checks.expect(!isStrictUtf8("\xC0\x80"), "an overlong NUL is rejected");
    checks.expect(!isStrictUtf8("\xE0\x80\xAF"),
                  "an overlong 3-byte form is rejected");
    checks.expect(!isStrictUtf8("\xED\xA0\x80"), "a surrogate is rejected");
    checks.expect(!isStrictUtf8("\xF4\x90\x80\x80"),
                  "past U+10FFFF is rejected");
    checks.expect(isStrictUtf8("\xF4\x8F\xBF\xBF"),
                  "U+10FFFF itself is valid");
    checks.expect(!isStrictUtf8("\xE4\xB8"),
                  "a truncated sequence is rejected");
}
