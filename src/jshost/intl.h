#pragma once

#include <map>
#include <string>

namespace macishtype {

// Per-JsEngineHost cache of ICU handles backing the Intl bindings. Handles are
// stored type-erased (void*) so this header stays free of ICU headers; intl.cpp
// casts and closes them. One cache per JS context, single-threaded, no locking.
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

    std::map<std::string, void *> breakIterators_;
    std::map<std::string, void *> dateFormatters_;
    std::map<std::string, void *> numberFormatters_;
    std::map<std::string, void *> collators_;
    std::map<std::string, void *> pluralRules_;
};

} // namespace macishtype
