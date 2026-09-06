#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace MacishType {

// Strict WHATWG UTF-8 validation: rejects overlongs, surrogates, and
// anything past U+10FFFF, and scans embedded NULs like any other byte.
bool isStrictUtf8(const uint8_t *data, size_t size);

inline bool isStrictUtf8(std::string_view text) {
    return isStrictUtf8(reinterpret_cast<const uint8_t *>(text.data()),
                        text.size());
}

} // namespace MacishType
