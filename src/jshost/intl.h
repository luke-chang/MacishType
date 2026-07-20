#pragma once

#include <map>
#include <string>

namespace macishtype {

// Per-JsEngineHost cache of ICU handles backing the Intl bindings. Handles are
// stored type-erased (void*) so this header stays free of ICU headers; intl.cpp
// casts and closes them. One cache per JS context, single-threaded, no locking.
// get-or-open methods are added per implementation phase.
class IntlCache {
public:
    IntlCache() = default;
    ~IntlCache();
    IntlCache(const IntlCache &) = delete;
    IntlCache &operator=(const IntlCache &) = delete;

    // Returns a cached UBreakIterator (as void*) for (type, locale), opening
    // one on first use. `type` is a UBreakIteratorType; `*status` receives a
    // UErrorCode when the open fails (and the return is null). void* and int
    // keep ICU headers out of this one.
    void *breakIterator(int type, const std::string &locale, int *status);

private:
    std::map<std::string, void *> breakIterators_;
    std::map<std::string, void *> dateFormatters_;
    std::map<std::string, void *> numberFormatters_;
    std::map<std::string, void *> collators_;
    std::map<std::string, void *> pluralRules_;
};

} // namespace macishtype
