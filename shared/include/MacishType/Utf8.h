#pragma once

#include <cstddef>
#include <cstdint>

namespace MacishType {

// Strict WHATWG UTF-8 validation: rejects overlongs, surrogates, and
// anything past U+10FFFF, and scans embedded NULs like any other byte.
bool isStrictUtf8(const uint8_t *data, size_t size);

} // namespace MacishType
