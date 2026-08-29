#include "FontCoverage.h"

#include <cstdint>
#include <map>
#include <vector>

#include <fontconfig/fontconfig.h>

#include <MacishType/FontCoverage.h>

#include "Log.h"

namespace MacishType {

namespace {

std::string computeCoverage() {
    if (FcInit() != FcTrue) {
        MACISHTYPE_WARN() << "fontCoverage: FcInit failed; claiming full "
                             "coverage";
        return fullCoverageBitmapBase64();
    }
    FcPattern *pattern = FcPatternCreate();
    FcObjectSet *objects = FcObjectSetBuild(FC_CHARSET, nullptr);
    FcFontSet *fonts = FcFontList(nullptr, pattern, objects);
    FcObjectSetDestroy(objects);
    FcPatternDestroy(pattern);
    if (fonts == nullptr) {
        MACISHTYPE_WARN() << "fontCoverage: FcFontList failed; claiming "
                             "full coverage";
        return fullCoverageBitmapBase64();
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
            if (plane > kCoverageMaxPlane) {
                continue;
            }
            auto &bitmap = planes
                               .try_emplace(plane, std::vector<uint8_t>(
                                                       kCoveragePlaneBytes, 0))
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
        return fullCoverageBitmapBase64();
    }
    MACISHTYPE_INFO() << "fontCoverage: " << codepointCount
                      << " codepoints across " << planes.size()
                      << " plane(s) from " << fontCount << " fonts";
    return base64Encode(serializeCoveragePlanes(planes));
}

} // namespace

const std::string &FontconfigCoverageProvider::coverageBitmapBase64() {
    static const std::string cached = computeCoverage();
    return cached;
}

} // namespace MacishType
