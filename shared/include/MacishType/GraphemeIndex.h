#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "MacishType/Intl.h"

namespace MacishType {

// Character indices in the engine contract count extended grapheme clusters;
// this resolves one string's boundaries once up front (utf16Offset still
// walks the byte prefix per call).
//
// Degradation ladder: valid UTF-8 without usable ICU falls back to code
// points (continuation bytes are never split, but combining marks and ZWJ
// sequences separate); raw byte indices are reserved for invalid UTF-8.
class GraphemeIndex {
public:
    // Borrows `utf8`, which must outlive this index.
    GraphemeIndex(IntlCache &cache, const std::string &utf8);
    GraphemeIndex(IntlCache &cache, std::string &&utf8) = delete;
    GraphemeIndex(const GraphemeIndex &) = delete;
    GraphemeIndex &operator=(const GraphemeIndex &) = delete;

    int count() const { return static_cast<int>(boundaries_.size()) - 1; }
    // All three clamp `index` to [0, count()].
    size_t byteOffset(int index) const;
    int utf16Offset(int index) const;
    // Borrowed from the indexed string; empty at index == count().
    std::string_view cluster(int index) const;
    // Borrowed from the indexed string: everything before `index`, so the
    // whole string at index == count().
    std::string_view prefix(int index) const;

private:
    const std::string &text_;
    std::vector<size_t> boundaries_;
};

// True when `text` is exactly one extended grapheme cluster; empty text is
// never one.
bool isSingleGrapheme(IntlCache &cache, const std::string &text);

} // namespace MacishType
