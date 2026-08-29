#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace MacishType {

// Cache of ICU handles, one per owning host instance. Handles are stored
// type-erased (void*) so this header stays free of ICU headers; IntlCache.cpp
// casts and closes them. Single-threaded, no locking.
class IntlCache {
public:
    IntlCache() = default;
    ~IntlCache();
    IntlCache(const IntlCache &) = delete;
    IntlCache &operator=(const IntlCache &) = delete;

    // One kind per ICU service; selects the backing map and the close function
    // used at teardown.
    enum Kind {
        kBreak,
        kDateFormat,
        kNumberFormat,
        kCollator,
        kPluralRules,
    };

    // Returns the cached handle for (kind, key), or nullptr if none is stored.
    void *get(Kind kind, const std::string &key);
    // Stores `handle` under (kind, key); the cache takes ownership.
    void put(Kind kind, const std::string &key, void *handle);

    // get-or-open convenience for a UBreakIterator (returned as void*) keyed on
    // (type, locale). `type` is a UBreakIteratorType; `*status` receives a
    // UErrorCode when the open fails (and the return is null). int keeps ICU
    // headers out of this one.
    void *breakIterator(int type, const std::string &locale, int *status);

private:
    std::map<std::string, void *> &mapFor(Kind kind);
    // Closes every ICU handle of `kind` and empties its map.
    void closeAll(Kind kind);

    std::map<std::string, void *> breakIterators_;
    std::map<std::string, void *> dateFormatters_;
    std::map<std::string, void *> numberFormatters_;
    std::map<std::string, void *> collators_;
    std::map<std::string, void *> pluralRules_;
};

// Byte offsets of every extended grapheme cluster boundary in `utf8`: starts
// at 0, ends at utf8.size(), so the cluster count is size() - 1. Empty input
// yields {0}; an empty vector means ICU is unusable.
std::vector<size_t> graphemeBoundariesUtf8(IntlCache &cache,
                                           const std::string &utf8);

// get-or-open the grapheme break iterator so the first segmentation on the
// typing path pays no ICU data load. Returns false when ICU fails.
bool warmGraphemeSegmenter(IntlCache &cache);

} // namespace MacishType
