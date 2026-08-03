#include "fontcoverage.h"

#include <cstdint>
#include <map>
#include <vector>

#include <fontconfig/fontconfig.h>

#include "../log.h"

namespace macishtype {

namespace {

constexpr size_t kPlaneBytes = 8192;
constexpr uint32_t kMaxPlane = 16;

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

std::string serializePlanes(
    const std::map<uint32_t, std::vector<uint8_t>> &planes) {
    std::string bytes;
    // The bitmap format leads with plane 0 unconditionally.
    static const std::vector<uint8_t> emptyPlane(kPlaneBytes, 0);
    const auto &planeZero =
        planes.count(0) != 0 ? planes.at(0) : emptyPlane;
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

std::string fullCoverage() {
    std::map<uint32_t, std::vector<uint8_t>> planes;
    for (uint32_t plane = 0; plane <= 3; plane++) {
        planes[plane] = std::vector<uint8_t>(kPlaneBytes, 0xff);
    }
    return base64Encode(serializePlanes(planes));
}

std::string computeCoverage() {
    if (FcInit() != FcTrue) {
        MACISHTYPE_WARN() << "fontCoverage: FcInit failed; claiming full "
                             "coverage";
        return fullCoverage();
    }
    FcPattern *pattern = FcPatternCreate();
    FcObjectSet *objects = FcObjectSetBuild(FC_CHARSET, nullptr);
    FcFontSet *fonts = FcFontList(nullptr, pattern, objects);
    FcObjectSetDestroy(objects);
    FcPatternDestroy(pattern);
    if (fonts == nullptr) {
        MACISHTYPE_WARN() << "fontCoverage: FcFontList failed; claiming "
                             "full coverage";
        return fullCoverage();
    }

    std::map<uint32_t, std::vector<uint8_t>> planes;
    size_t codepointCount = 0;
    for (int i = 0; i < fonts->nfont; i++) {
        FcCharSet *charset = nullptr;
        if (FcPatternGetCharSet(fonts->fonts[i], FC_CHARSET, 0, &charset) !=
                FcResultMatch ||
            charset == nullptr) {
            continue;
        }
        FcChar32 pageMap[FC_CHARSET_MAP_SIZE];
        FcChar32 next = 0;
        for (FcChar32 base = FcCharSetFirstPage(charset, pageMap, &next);
             base != FC_CHARSET_DONE;
             base = FcCharSetNextPage(charset, pageMap, &next)) {
            uint32_t plane = base >> 16;
            if (plane > kMaxPlane) {
                continue;
            }
            auto &bitmap = planes
                               .try_emplace(plane, std::vector<uint8_t>(
                                                       kPlaneBytes, 0))
                               .first->second;
            // A page covers 256 codepoints; both layouts are LSB-first, so
            // the page words spread byte-by-byte into the plane bitmap.
            size_t offset = (base & 0xffffU) >> 3;
            for (size_t word = 0; word < FC_CHARSET_MAP_SIZE; word++) {
                for (size_t byte = 0; byte < 4; byte++) {
                    uint8_t bits =
                        (pageMap[word] >> (8 * byte)) & 0xffU;
                    uint8_t before = bitmap[offset + word * 4 + byte];
                    bitmap[offset + word * 4 + byte] = before | bits;
                    codepointCount +=
                        __builtin_popcount(bits & ~before);
                }
            }
        }
    }
    int fontCount = fonts->nfont;
    FcFontSetDestroy(fonts);

    if (planes.empty() || codepointCount == 0) {
        MACISHTYPE_WARN() << "fontCoverage: no charsets found; claiming "
                             "full coverage";
        return fullCoverage();
    }
    MACISHTYPE_INFO() << "fontCoverage: " << codepointCount
                      << " codepoints across " << planes.size()
                      << " plane(s) from " << fontCount << " fonts";
    return base64Encode(serializePlanes(planes));
}

} // namespace

const std::string &fontCoverageBitmapBase64() {
    static const std::string cached = computeCoverage();
    return cached;
}

} // namespace macishtype
