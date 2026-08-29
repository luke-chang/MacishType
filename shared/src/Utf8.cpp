#include "MacishType/Utf8.h"

namespace MacishType {

bool isStrictUtf8(const uint8_t *data, size_t size) {
    size_t i = 0;
    while (i < size) {
        uint8_t byte = data[i];
        if (byte <= 0x7F) {
            i += 1;
            continue;
        }
        size_t continuations;
        uint8_t lower = 0x80;
        uint8_t upper = 0xBF;
        if (byte >= 0xC2 && byte <= 0xDF) {
            continuations = 1;
        } else if (byte == 0xE0) {
            continuations = 2;
            lower = 0xA0; // reject overlongs
        } else if (byte == 0xED) {
            continuations = 2;
            upper = 0x9F; // reject surrogates
        } else if (byte >= 0xE1 && byte <= 0xEF) {
            continuations = 2;
        } else if (byte == 0xF0) {
            continuations = 3;
            lower = 0x90; // reject overlongs
        } else if (byte == 0xF4) {
            continuations = 3;
            upper = 0x8F; // reject > U+10FFFF
        } else if (byte >= 0xF1 && byte <= 0xF3) {
            continuations = 3;
        } else {
            return false; // C0/C1, F5-FF, or a stray continuation byte
        }
        if (size - i - 1 < continuations) {
            return false;
        }
        if (data[i + 1] < lower || data[i + 1] > upper) {
            return false;
        }
        for (size_t k = 2; k <= continuations; ++k) {
            if (data[i + k] < 0x80 || data[i + k] > 0xBF) {
                return false;
            }
        }
        i += continuations + 1;
    }
    return true;
}

} // namespace MacishType
