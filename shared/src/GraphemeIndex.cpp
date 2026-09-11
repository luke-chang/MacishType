#include "MacishType/GraphemeIndex.h"

#include <algorithm>
#include <numeric>

#include "MacishType/Utf8.h"

namespace MacishType {

namespace {

// The no-ICU approximation: code points, not clusters.
std::vector<size_t> codePointBoundaries(const std::string &utf8) {
    std::vector<size_t> boundaries;
    boundaries.reserve(utf8.size() + 1);
    boundaries.push_back(0);
    for (size_t i = 1; i <= utf8.size(); i++) {
        if (i == utf8.size() ||
            (static_cast<unsigned char>(utf8[i]) & 0xC0) != 0x80) {
            boundaries.push_back(i);
        }
    }
    return boundaries;
}

} // namespace

GraphemeIndex::GraphemeIndex(IntlCache &cache, const std::string &utf8)
    : text_(utf8) {
    if (isStrictUtf8(utf8)) {
        boundaries_ = graphemeBoundariesUtf8(cache, utf8);
        if (boundaries_.empty()) {
            boundaries_ = codePointBoundaries(utf8);
        }
    } else {
        boundaries_.resize(utf8.size() + 1);
        std::iota(boundaries_.begin(), boundaries_.end(), size_t{0});
    }
}

size_t GraphemeIndex::byteOffset(int index) const {
    return boundaries_[static_cast<size_t>(std::clamp(index, 0, count()))];
}

std::string_view GraphemeIndex::cluster(int index) const {
    size_t start = byteOffset(index);
    return std::string_view(text_).substr(start, byteOffset(index + 1) - start);
}

std::string_view GraphemeIndex::prefix(int index) const {
    return std::string_view(text_).substr(0, byteOffset(index));
}

int GraphemeIndex::utf16Offset(int index) const {
    size_t end = byteOffset(index);
    int units = 0;
    for (size_t i = 0; i < end;) {
        // Lead-byte arithmetic is enough here: the constructor already
        // steered invalid UTF-8 onto byte boundaries, and a four-byte
        // sequence is the only one that widens to a surrogate pair.
        unsigned char lead = static_cast<unsigned char>(text_[i]);
        size_t length = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
        units += length == 4 ? 2 : 1;
        i += length;
    }
    return units;
}

bool isSingleGrapheme(IntlCache &cache, const std::string &text) {
    // The all-ASCII path keeps per-keystroke gates (including named keys like
    // "Enter") off the segmenter.
    bool allAscii = std::all_of(text.begin(), text.end(), [](char byte) {
        return static_cast<unsigned char>(byte) <= 0x7F;
    });
    if (allAscii) {
        return text.size() == 1;
    }
    return GraphemeIndex(cache, text).count() == 1;
}

} // namespace MacishType
