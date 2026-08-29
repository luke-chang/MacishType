#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace MacishType {

// Codepoint-coverage bitmap format shared by every platform's
// FontCoverageProvider: plane 0's 8192-byte bitmap leads unconditionally;
// each additional plane is one plane-number byte followed by its 8192-byte
// bitmap; bits are LSB-first within a byte; the whole payload is base64.
// The format matches the macOS host byte for byte.
inline constexpr size_t kCoveragePlaneBytes = 8192;
inline constexpr uint32_t kCoverageMaxPlane = 16;

std::string base64Encode(const std::string &data);
std::string serializeCoveragePlanes(
    const std::map<uint32_t, std::vector<uint8_t>> &planes);

// Planes 0-3 fully set — "every candidate renders", which disables
// filtering. Providers use it when enumeration fails; core uses it when no
// FontCoverageProvider is installed at all.
const std::string &fullCoverageBitmapBase64();

} // namespace MacishType
