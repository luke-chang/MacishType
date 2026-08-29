#include "MacishType/FontCoverage.h"

namespace macishtype {

std::string base64Encode(const std::string &data) {
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string encoded;
    encoded.reserve((data.size() + 2) / 3 * 4);
    size_t i = 0;
    while (i + 2 < data.size()) {
        uint32_t chunk = (static_cast<unsigned char>(data[i]) << 16) |
                         (static_cast<unsigned char>(data[i + 1]) << 8) |
                         static_cast<unsigned char>(data[i + 2]);
        encoded.push_back(alphabet[(chunk >> 18) & 0x3f]);
        encoded.push_back(alphabet[(chunk >> 12) & 0x3f]);
        encoded.push_back(alphabet[(chunk >> 6) & 0x3f]);
        encoded.push_back(alphabet[chunk & 0x3f]);
        i += 3;
    }
    if (i < data.size()) {
        uint32_t chunk = static_cast<unsigned char>(data[i]) << 16;
        bool hasSecond = i + 1 < data.size();
        if (hasSecond) {
            chunk |= static_cast<unsigned char>(data[i + 1]) << 8;
        }
        encoded.push_back(alphabet[(chunk >> 18) & 0x3f]);
        encoded.push_back(alphabet[(chunk >> 12) & 0x3f]);
        encoded.push_back(hasSecond ? alphabet[(chunk >> 6) & 0x3f] : '=');
        encoded.push_back('=');
    }
    return encoded;
}

std::string serializeCoveragePlanes(
    const std::map<uint32_t, std::vector<uint8_t>> &planes) {
    std::string bytes;
    // The bitmap format leads with plane 0 unconditionally.
    static const std::vector<uint8_t> emptyPlane(kCoveragePlaneBytes, 0);
    const auto &planeZero = planes.count(0) != 0 ? planes.at(0) : emptyPlane;
    bytes.append(reinterpret_cast<const char *>(planeZero.data()),
                 planeZero.size());
    for (const auto &[plane, bitmap] : planes) {
        if (plane == 0) {
            continue;
        }
        bytes.push_back(static_cast<char>(plane));
        bytes.append(reinterpret_cast<const char *>(bitmap.data()),
                     bitmap.size());
    }
    return bytes;
}

const std::string &fullCoverageBitmapBase64() {
    static const std::string cached = [] {
        std::map<uint32_t, std::vector<uint8_t>> planes;
        for (uint32_t plane = 0; plane <= 3; plane++) {
            planes[plane] = std::vector<uint8_t>(kCoveragePlaneBytes, 0xff);
        }
        return base64Encode(serializeCoveragePlanes(planes));
    }();
    return cached;
}

} // namespace macishtype
