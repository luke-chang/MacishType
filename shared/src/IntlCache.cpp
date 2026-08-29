#include "MacishType/Intl.h"

#include <cstdint>
#include <string>
#include <vector>

#include "MacishType/IntlIcu.h"

namespace MacishType {

// Bounds the ICU handles cached per kind. The cache keys embed engine-
// controlled locale/skeleton/pattern strings, so without a cap an engine could
// mint unbounded distinct keys and leak one native handle per key for the
// host's lifetime. A normal engine's locale/option set stays far below this.
constexpr size_t kMaxHandlesPerKind = 512;

IntlCache::~IntlCache() {
    closeAll(kBreak);
    closeAll(kDateFormat);
    closeAll(kNumberFormat);
    closeAll(kCollator);
    closeAll(kPluralRules);
}

// Closes every cached handle of `kind` with its matching ICU close function
// and empties the map. Used at teardown and when the per-kind cap is hit.
void IntlCache::closeAll(Kind kind) {
    auto &store = mapFor(kind);
    for (auto &[key, handle] : store) {
        (void)key;
        switch (kind) {
        case kBreak:
            ubrk_close(static_cast<UBreakIterator *>(handle));
            break;
        case kDateFormat:
            udat_close(static_cast<UDateFormat *>(handle));
            break;
        case kNumberFormat:
            unumf_close(static_cast<UNumberFormatter *>(handle));
            break;
        case kCollator:
            ucol_close(static_cast<UCollator *>(handle));
            break;
        case kPluralRules:
            uplrules_close(static_cast<UPluralRules *>(handle));
            break;
        }
    }
    store.clear();
}

std::map<std::string, void *> &IntlCache::mapFor(Kind kind) {
    switch (kind) {
    case kBreak:
        return breakIterators_;
    case kDateFormat:
        return dateFormatters_;
    case kNumberFormat:
        return numberFormatters_;
    case kCollator:
        return collators_;
    case kPluralRules:
        return pluralRules_;
    }
    return breakIterators_; // unreachable
}

void *IntlCache::get(Kind kind, const std::string &key) {
    auto &store = mapFor(kind);
    auto existing = store.find(key);
    return existing == store.end() ? nullptr : existing->second;
}

void IntlCache::put(Kind kind, const std::string &key, void *handle) {
    auto &store = mapFor(kind);
    if (store.size() >= kMaxHandlesPerKind) {
        // Cap reached: close and drop every handle of this kind, then start
        // over. Only a pathological engine minting unbounded keys hits this.
        // Safe because no Intl native touches a cached handle once engine JS
        // may run: arguments are coerced to owned buffers before a handle is
        // acquired, and ICU results are materialized into locals before the
        // JS result is built — so no live handle (this call's, or a re-entrant
        // outer frame's) can be among those closed here.
        closeAll(kind);
    }
    store[key] = handle;
}

void *IntlCache::breakIterator(int type, const std::string &locale,
                               int *status) {
    std::string key = std::to_string(type) + "|" + locale;
    if (void *cached = get(kBreak, key)) {
        return cached;
    }
    UErrorCode code = U_ZERO_ERROR;
    UBreakIterator *iterator = ubrk_open(static_cast<UBreakIteratorType>(type),
                                         locale.c_str(), nullptr, 0, &code);
    if (U_FAILURE(code)) {
        if (iterator != nullptr) {
            ubrk_close(iterator);
        }
        *status = code;
        return nullptr;
    }
    put(kBreak, key, iterator);
    return iterator;
}

std::vector<size_t> graphemeBoundariesUtf8(IntlCache &cache,
                                           const std::string &utf8) {
    // Re-acquire from the cache on every call: the per-kind cap can have
    // closed the iterator since. No JS runs while it is held, so the eviction
    // re-entrancy hazard of the Intl natives does not apply here.
    int openStatus = U_ZERO_ERROR;
    auto *iterator = static_cast<UBreakIterator *>(
        cache.breakIterator(UBRK_CHARACTER, "", &openStatus));
    if (iterator == nullptr) {
        return {};
    }
    UErrorCode status = U_ZERO_ERROR;
    UText text = UTEXT_INITIALIZER;
    utext_openUTF8(&text, utf8.data(), static_cast<int64_t>(utf8.size()),
                   &status);
    if (U_FAILURE(status)) {
        return {};
    }
    // The iterator holds a shallow clone of `text`, which reads `utf8`'s
    // buffer directly; both must outlive the iteration.
    ubrk_setUText(iterator, &text, &status);
    if (U_FAILURE(status)) {
        utext_close(&text);
        return {};
    }
    // UTF-8 UText boundaries are native indexes, i.e. byte offsets.
    std::vector<size_t> boundaries;
    boundaries.push_back(static_cast<size_t>(ubrk_first(iterator)));
    for (int32_t next = ubrk_next(iterator); next != UBRK_DONE;
         next = ubrk_next(iterator)) {
        boundaries.push_back(static_cast<size_t>(next));
    }
    utext_close(&text);
    return boundaries;
}

bool warmGraphemeSegmenter(IntlCache &cache) {
    int status = U_ZERO_ERROR;
    return cache.breakIterator(UBRK_CHARACTER, "", &status) != nullptr;
}

} // namespace MacishType
