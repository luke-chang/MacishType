#include "macishtype/intl.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "macishtype/enginehost.h"
#include "macishtype/qjsutil.h"

#include "intl_icu.h"

namespace macishtype {

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

IntlCache &JsEngineHost::intlCache() {
    if (!intlCache_) {
        intlCache_ = std::make_unique<IntlCache>();
    }
    return *intlCache_;
}

namespace {

// Converts a BCP-47 language tag to an ICU locale ID (e.g. "zh-Hant" →
// "zh_Hant"). Falls back to the raw tag when ICU cannot parse it, so a bad
// tag degrades to ICU's own locale fallback rather than an error. Unicode
// extensions (-u-ca-, -u-nu-) are carried through into keywords.
std::string toIcuLocale(const std::string &tag) {
    if (tag.empty()) {
        return {};
    }
    char buffer[ULOC_FULLNAME_CAPACITY];
    UErrorCode status = U_ZERO_ERROR;
    int32_t length = uloc_forLanguageTag(tag.c_str(), buffer, sizeof(buffer),
                                         nullptr, &status);
    if (U_FAILURE(status) || length <= 0) {
        return tag;
    }
    return std::string(buffer, length);
}

// The canonical BCP-47 tag for an ICU locale ID, for resolvedOptions().locale.
std::string canonicalLanguageTag(const std::string &icuLocale) {
    char buffer[ULOC_FULLNAME_CAPACITY];
    UErrorCode status = U_ZERO_ERROR;
    int32_t length = uloc_toLanguageTag(icuLocale.c_str(), buffer,
                                        sizeof(buffer), false, &status);
    if (U_FAILURE(status) || length <= 0) {
        return icuLocale;
    }
    return std::string(buffer, length);
}

// Maps an ECMA-402 Segmenter granularity to a UBreakIteratorType. The shim
// validates the string first, so an unknown value here is a host bug.
bool granularityType(const std::string &granularity, UBreakIteratorType *out) {
    if (granularity == "grapheme") {
        *out = UBRK_CHARACTER;
    } else if (granularity == "word") {
        *out = UBRK_WORD;
    } else if (granularity == "sentence") {
        *out = UBRK_SENTENCE;
    } else {
        return false;
    }
    return true;
}

// UTF-8 → UTF-16 for ICU input (patterns, skeletons, zone IDs — all BMP text).
std::vector<UChar> toUChars(const std::string &utf8) {
    if (utf8.empty()) {
        return {};
    }
    UErrorCode status = U_ZERO_ERROR;
    int32_t needed = 0;
    u_strFromUTF8(nullptr, 0, &needed, utf8.data(),
                  static_cast<int32_t>(utf8.size()), &status);
    std::vector<UChar> out(needed > 0 ? needed : 0);
    status = U_ZERO_ERROR;
    u_strFromUTF8(out.data(), needed, nullptr, utf8.data(),
                  static_cast<int32_t>(utf8.size()), &status);
    if (U_FAILURE(status)) {
        return {};
    }
    return out;
}

// UTF-16 → UTF-8 for ICU output that becomes a C++ key/string (zone IDs).
std::string fromUChars(const UChar *text, int32_t length) {
    if (text == nullptr || length <= 0) {
        return {};
    }
    UErrorCode status = U_ZERO_ERROR;
    int32_t needed = 0;
    u_strToUTF8(nullptr, 0, &needed, text, length, &status);
    std::string out(needed > 0 ? needed : 0, '\0');
    status = U_ZERO_ERROR;
    u_strToUTF8(out.data(), needed, nullptr, text, length, &status);
    if (U_FAILURE(status)) {
        return {};
    }
    return out;
}

// Reads the resolved hour cycle off a generated pattern by finding its hour
// field letter, skipping quoted literals. Returns nullptr when the pattern
// carries no hour field.
const char *hourCycleFromPattern(const UChar *pattern, int32_t length) {
    bool inQuote = false;
    for (int32_t i = 0; i < length; i++) {
        UChar c = pattern[i];
        if (c == u'\'') {
            inQuote = !inQuote;
            continue;
        }
        if (inQuote) {
            continue;
        }
        switch (c) {
        case u'h':
            return "h12";
        case u'H':
            return "h23";
        case u'K':
            return "h11";
        case u'k':
            return "h24";
        default:
            break;
        }
    }
    return nullptr;
}

// Maps a UDateFormatField to its ECMA-402 formatToParts type.
const char *dateFieldType(int32_t field) {
    switch (field) {
    case UDAT_ERA_FIELD:
        return "era";
    case UDAT_YEAR_FIELD:
    case UDAT_YEAR_WOY_FIELD:
    case UDAT_EXTENDED_YEAR_FIELD:
    case UDAT_YEAR_NAME_FIELD:
        return "year";
    case UDAT_MONTH_FIELD:
    case UDAT_STANDALONE_MONTH_FIELD:
        return "month";
    case UDAT_DATE_FIELD:
        return "day";
    case UDAT_HOUR_OF_DAY1_FIELD:
    case UDAT_HOUR_OF_DAY0_FIELD:
    case UDAT_HOUR1_FIELD:
    case UDAT_HOUR0_FIELD:
        return "hour";
    case UDAT_MINUTE_FIELD:
        return "minute";
    case UDAT_SECOND_FIELD:
        return "second";
    case UDAT_FRACTIONAL_SECOND_FIELD:
        return "fractionalSecond";
    case UDAT_DAY_OF_WEEK_FIELD:
    case UDAT_STANDALONE_DAY_FIELD:
    case UDAT_DOW_LOCAL_FIELD:
        return "weekday";
    case UDAT_AM_PM_FIELD:
    case UDAT_AM_PM_MIDNIGHT_NOON_FIELD:
    case UDAT_FLEXIBLE_DAY_PERIOD_FIELD:
        return "dayPeriod";
    case UDAT_TIMEZONE_FIELD:
    case UDAT_TIMEZONE_RFC_FIELD:
    case UDAT_TIMEZONE_GENERIC_FIELD:
    case UDAT_TIMEZONE_SPECIAL_FIELD:
    case UDAT_TIMEZONE_LOCALIZED_GMT_OFFSET_FIELD:
    case UDAT_TIMEZONE_ISO_FIELD:
    case UDAT_TIMEZONE_ISO_LOCAL_FIELD:
        return "timeZoneName";
    default:
        return "unknown";
    }
}

// get-or-open a UDateFormat bound to (localeTag, timeZone, pattern). The
// pattern already encodes the field widths; the locale keyword carries the
// calendar and numbering system.
UDateFormat *dateFormatter(IntlCache &cache, const std::string &localeTag,
                           const std::string &timeZone, const UChar *pattern,
                           int32_t patternLength, int *errorOut) {
    std::string key = localeTag + "\x01" + timeZone + "\x01" +
                      fromUChars(pattern, patternLength);
    if (void *cached = cache.get(IntlCache::kDateFormat, key)) {
        return static_cast<UDateFormat *>(cached);
    }
    std::string icuLocale = toIcuLocale(localeTag);
    std::vector<UChar> zone = toUChars(timeZone);
    UErrorCode status = U_ZERO_ERROR;
    UDateFormat *formatter =
        udat_open(UDAT_PATTERN, UDAT_PATTERN, icuLocale.c_str(),
                  zone.empty() ? nullptr : zone.data(),
                  static_cast<int32_t>(zone.size()), pattern, patternLength,
                  &status);
    if (U_FAILURE(status)) {
        if (formatter != nullptr) {
            udat_close(formatter);
        }
        *errorOut = status;
        return nullptr;
    }
    cache.put(IntlCache::kDateFormat, key, formatter);
    return formatter;
}

// Appends {type, value} to `array` at `index`, from a slice of `text`.
void pushPart(JSContext *ctx, JSValue array, uint32_t index, const char *type,
              const UChar *text, int32_t begin, int32_t end) {
    JSValue part = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, part, "type", JS_NewString(ctx, type));
    JS_SetPropertyStr(
        ctx, part, "value",
        JS_NewStringUTF16(ctx, reinterpret_cast<const uint16_t *>(text + begin),
                          static_cast<size_t>(end - begin)));
    JS_SetPropertyUint32(ctx, array, index, part);
}

// The numbering system name for an ICU locale (respects the -u-nu- keyword).
std::string numberingSystemName(const std::string &icuLocale) {
    UErrorCode status = U_ZERO_ERROR;
    UNumberingSystem *system = unumsys_open(icuLocale.c_str(), &status);
    std::string name = "latn";
    if (U_SUCCESS(status) && system != nullptr) {
        const char *value = unumsys_getName(system);
        if (value != nullptr) {
            name = value;
        }
    }
    if (system != nullptr) {
        unumsys_close(system);
    }
    return name;
}

// get-or-open a UNumberFormatter for (localeTag, skeleton). The skeleton
// encodes the entire ECMA-402 option set, so it doubles as the cache key.
UNumberFormatter *numberFormatter(IntlCache &cache, const std::string &localeTag,
                                  const UChar *skeleton, int32_t skeletonLength,
                                  int *errorOut) {
    std::string key = localeTag + "\x01" + fromUChars(skeleton, skeletonLength);
    if (void *cached = cache.get(IntlCache::kNumberFormat, key)) {
        return static_cast<UNumberFormatter *>(cached);
    }
    std::string icuLocale = toIcuLocale(localeTag);
    UErrorCode status = U_ZERO_ERROR;
    UNumberFormatter *formatter = unumf_openForSkeletonAndLocale(
        skeleton, skeletonLength, icuLocale.c_str(), &status);
    if (U_FAILURE(status)) {
        if (formatter != nullptr) {
            unumf_close(formatter);
        }
        *errorOut = status;
        return nullptr;
    }
    cache.put(IntlCache::kNumberFormat, key, formatter);
    return formatter;
}

// INTEGER and FRACTION span the separators nested inside them, so they paint
// first and the separators overwrite the overlap.
bool isNumberContainer(int32_t field) {
    return field == UNUM_INTEGER_FIELD || field == UNUM_FRACTION_FIELD;
}

// Maps a UNumberFormatField to its ECMA-402 formatToParts type. Sign fields
// resolve to minus/plus by inspecting the first character of the run.
const char *numberFieldType(int32_t field, UChar first) {
    switch (field) {
    case UNUM_INTEGER_FIELD:
        return "integer";
    case UNUM_FRACTION_FIELD:
        return "fraction";
    case UNUM_DECIMAL_SEPARATOR_FIELD:
        return "decimal";
    case UNUM_GROUPING_SEPARATOR_FIELD:
        return "group";
    case UNUM_CURRENCY_FIELD:
        return "currency";
    case UNUM_PERCENT_FIELD:
        return "percentSign";
    case UNUM_SIGN_FIELD:
        return (first == u'-' || first == u'−') ? "minusSign" : "plusSign";
    case UNUM_EXPONENT_SYMBOL_FIELD:
        return "exponentSeparator";
    case UNUM_EXPONENT_SIGN_FIELD:
        return (first == u'-' || first == u'−') ? "exponentMinusSign"
                                                      : "exponentPlusSign";
    case UNUM_EXPONENT_FIELD:
        return "exponentInteger";
    case UNUM_MEASURE_UNIT_FIELD:
        return "unit";
    case UNUM_COMPACT_FIELD:
        return "compact";
    default:
        return "literal";
    }
}

// get-or-open a UPluralRules for (localeTag, type). `type` is a UPluralType
// (0 cardinal, 1 ordinal).
UPluralRules *pluralRules(IntlCache &cache, const std::string &localeTag,
                          int type, int *errorOut) {
    std::string key = localeTag + "\x01" + std::to_string(type);
    if (void *cached = cache.get(IntlCache::kPluralRules, key)) {
        return static_cast<UPluralRules *>(cached);
    }
    std::string icuLocale = toIcuLocale(localeTag);
    UErrorCode status = U_ZERO_ERROR;
    UPluralRules *rules = uplrules_openForType(
        icuLocale.c_str(), static_cast<UPluralType>(type), &status);
    if (U_FAILURE(status)) {
        if (rules != nullptr) {
            uplrules_close(rules);
        }
        *errorOut = status;
        return nullptr;
    }
    cache.put(IntlCache::kPluralRules, key, rules);
    return rules;
}

// get-or-open a UCollator for (localeTag, signature). The signature is the
// comma-joined option tuple "strength,caseLevel,numeric,caseFirst,alternate"
// the shim derives from ECMA-402 options; it is parsed once, on the miss that
// opens the collator, then reused as the cache key.
UCollator *collator(IntlCache &cache, const std::string &localeTag,
                    const std::string &signature, int *errorOut) {
    std::string key = localeTag + "\x01" + signature;
    if (void *cached = cache.get(IntlCache::kCollator, key)) {
        return static_cast<UCollator *>(cached);
    }
    std::string icuLocale = toIcuLocale(localeTag);
    UErrorCode status = U_ZERO_ERROR;
    UCollator *coll = ucol_open(icuLocale.c_str(), &status);
    if (U_FAILURE(status)) {
        if (coll != nullptr) {
            ucol_close(coll);
        }
        *errorOut = status;
        return nullptr;
    }
    int strength = 2;
    int caseLevel = 0;
    int numeric = 0;
    int caseFirst = 0;
    int alternate = 0;
    std::sscanf(signature.c_str(), "%d,%d,%d,%d,%d", &strength, &caseLevel,
                &numeric, &caseFirst, &alternate);
    UColAttributeValue strengthValue = strength == 0   ? UCOL_PRIMARY
                                       : strength == 1 ? UCOL_SECONDARY
                                       : strength == 3 ? UCOL_QUATERNARY
                                                       : UCOL_TERTIARY;
    ucol_setStrength(coll, strengthValue);
    UErrorCode attr = U_ZERO_ERROR;
    ucol_setAttribute(coll, UCOL_CASE_LEVEL, caseLevel ? UCOL_ON : UCOL_OFF,
                      &attr);
    ucol_setAttribute(coll, UCOL_NUMERIC_COLLATION,
                      numeric ? UCOL_ON : UCOL_OFF, &attr);
    ucol_setAttribute(coll, UCOL_CASE_FIRST,
                      caseFirst == 1   ? UCOL_UPPER_FIRST
                      : caseFirst == 2 ? UCOL_LOWER_FIRST
                                       : UCOL_OFF,
                      &attr);
    ucol_setAttribute(coll, UCOL_ALTERNATE_HANDLING,
                      alternate ? UCOL_SHIFTED : UCOL_NON_IGNORABLE, &attr);
    cache.put(IntlCache::kCollator, key, coll);
    return coll;
}

} // namespace

JSValue JsEngineHost::nativeIntlSegment(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv) {
    (void)thisVal;
    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "intlSegment: expected 3 arguments");
    }
    UBreakIteratorType type;
    if (!granularityType(qjs::toString(ctx, argv[1]), &type)) {
        return JS_ThrowTypeError(ctx, "intlSegment: unknown granularity");
    }
    std::string locale = toIcuLocale(qjs::toString(ctx, argv[0]));

    // UTF-16 throughout: the offsets ICU reports are already in String#length
    // units, so they need no conversion before reaching the shim.
    size_t length = 0;
    const uint16_t *text = JS_ToCStringLenUTF16(ctx, &length, argv[2]);
    if (text == nullptr) {
        return JS_EXCEPTION;
    }

    int openStatus = U_ZERO_ERROR;
    auto *iterator = static_cast<UBreakIterator *>(
        hostOf(ctx)->intlCache().breakIterator(type, locale, &openStatus));
    if (iterator == nullptr) {
        JS_FreeCStringUTF16(ctx, text);
        return JS_ThrowPlainError(ctx, "intlSegment: ICU open failed (%d)",
                                  openStatus);
    }

    UErrorCode status = U_ZERO_ERROR;
    ubrk_setText(iterator, reinterpret_cast<const UChar *>(text),
                 static_cast<int32_t>(length), &status);
    if (U_FAILURE(status)) {
        JS_FreeCStringUTF16(ctx, text);
        return JS_ThrowPlainError(ctx, "intlSegment: ICU setText failed (%d)",
                                  status);
    }

    // Collect the boundaries (and word-like flags) into locals while the cached
    // iterator is live: building the JS arrays below can run engine JS (a
    // tampered Array.prototype setter), which under the handle cap could evict
    // and close this iterator via re-entrancy. Materializing first means the
    // iterator is never touched once JS may run.
    // boundaries[i]..boundaries[i+1] spans segment i; for the whole string it
    // runs [0, …, length], so the segment count is boundaries.length - 1.
    std::vector<int32_t> boundaryOffsets;
    std::vector<bool> wordLikeFlags;
    boundaryOffsets.push_back(ubrk_first(iterator));
    for (int32_t next = ubrk_next(iterator); next != UBRK_DONE;
         next = ubrk_next(iterator)) {
        boundaryOffsets.push_back(next);
        if (type == UBRK_WORD) {
            // A rule status in the UBRK_WORD_NONE range marks whitespace and
            // punctuation runs; anything else (letters, numbers, kana, …) is
            // word-like, per ECMA-402's isWordLike.
            int32_t rule = ubrk_getRuleStatus(iterator);
            wordLikeFlags.push_back(
                !(rule >= UBRK_WORD_NONE && rule < UBRK_WORD_NONE_LIMIT));
        }
    }
    JS_FreeCStringUTF16(ctx, text);

    JSValue boundaries = JS_NewArray(ctx);
    for (size_t i = 0; i < boundaryOffsets.size(); i++) {
        JS_SetPropertyUint32(ctx, boundaries, static_cast<uint32_t>(i),
                             JS_NewInt32(ctx, boundaryOffsets[i]));
    }
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "boundaries", boundaries);
    if (type == UBRK_WORD) {
        JSValue wordLike = JS_NewArray(ctx);
        for (size_t i = 0; i < wordLikeFlags.size(); i++) {
            JS_SetPropertyUint32(ctx, wordLike, static_cast<uint32_t>(i),
                                 JS_NewBool(ctx, wordLikeFlags[i]));
        }
        JS_SetPropertyStr(ctx, result, "wordLike", wordLike);
    }
    return result;
}

JSValue JsEngineHost::nativeIntlDateTimeResolve(JSContext *ctx,
                                                JSValueConst thisVal, int argc,
                                                JSValueConst *argv) {
    (void)thisVal;
    if (argc < 5) {
        return JS_ThrowTypeError(ctx, "intlDateTimeResolve: expected 5 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    std::string skeleton = qjs::toString(ctx, argv[1]);
    std::string requestedZone = qjs::toString(ctx, argv[2]);
    int32_t dateStyle = -1;
    int32_t timeStyle = -1;
    JS_ToInt32(ctx, &dateStyle, argv[3]);
    JS_ToInt32(ctx, &timeStyle, argv[4]);

    std::string icuLocale = toIcuLocale(localeTag);
    JSValue result = JS_NewObject(ctx);

    // Time zone: validate/canonicalize an explicit zone, else read the system
    // default (the value McBopomofo's timezone macros surface).
    std::string resolvedZone;
    if (requestedZone.empty()) {
        UErrorCode status = U_ZERO_ERROR;
        int32_t length = ucal_getDefaultTimeZone(nullptr, 0, &status);
        std::vector<UChar> buffer(length > 0 ? length + 1 : 1);
        status = U_ZERO_ERROR;
        length = ucal_getDefaultTimeZone(buffer.data(),
                                         static_cast<int32_t>(buffer.size()),
                                         &status);
        if (U_SUCCESS(status)) {
            resolvedZone = fromUChars(buffer.data(), length);
        }
    } else {
        std::vector<UChar> zone = toUChars(requestedZone);
        UErrorCode status = U_ZERO_ERROR;
        UBool isSystem = false;
        std::vector<UChar> canonical(64);
        int32_t length = ucal_getCanonicalTimeZoneID(
            zone.data(), static_cast<int32_t>(zone.size()), canonical.data(),
            static_cast<int32_t>(canonical.size()), &isSystem, &status);
        if (status == U_BUFFER_OVERFLOW_ERROR) {
            canonical.resize(length + 1);
            status = U_ZERO_ERROR;
            length = ucal_getCanonicalTimeZoneID(
                zone.data(), static_cast<int32_t>(zone.size()),
                canonical.data(), static_cast<int32_t>(canonical.size()),
                &isSystem, &status);
        }
        if (U_FAILURE(status) || !isSystem) {
            JS_SetPropertyStr(ctx, result, "ok", JS_NewBool(ctx, false));
            JS_SetPropertyStr(ctx, result, "error",
                              JS_NewString(ctx, "invalid-timezone"));
            return result;
        }
        resolvedZone = fromUChars(canonical.data(), length);
    }

    // Pattern: a fixed date/time style extracts its own pattern; otherwise the
    // skeleton is matched to a locale-appropriate one.
    std::vector<UChar> patternBuffer(256);
    int32_t patternLength = 0;
    UErrorCode status = U_ZERO_ERROR;
    if (dateStyle >= 0 || timeStyle >= 0) {
        std::vector<UChar> zone = toUChars(resolvedZone);
        UDateFormat *styled = udat_open(
            timeStyle >= 0 ? static_cast<UDateFormatStyle>(timeStyle)
                           : UDAT_NONE,
            dateStyle >= 0 ? static_cast<UDateFormatStyle>(dateStyle)
                           : UDAT_NONE,
            icuLocale.c_str(), zone.empty() ? nullptr : zone.data(),
            static_cast<int32_t>(zone.size()), nullptr, 0, &status);
        if (U_SUCCESS(status)) {
            patternLength = udat_toPattern(styled, false, patternBuffer.data(),
                                           static_cast<int32_t>(
                                               patternBuffer.size()),
                                           &status);
        }
        if (styled != nullptr) {
            udat_close(styled);
        }
    } else {
        UDateTimePatternGenerator *generator =
            udatpg_open(icuLocale.c_str(), &status);
        if (U_SUCCESS(status)) {
            std::vector<UChar> skeletonU = toUChars(skeleton);
            patternLength = udatpg_getBestPatternWithOptions(
                generator, skeletonU.data(),
                static_cast<int32_t>(skeletonU.size()),
                UDATPG_MATCH_ALL_FIELDS_LENGTH, patternBuffer.data(),
                static_cast<int32_t>(patternBuffer.size()), &status);
        }
        if (generator != nullptr) {
            udatpg_close(generator);
        }
    }
    if (U_FAILURE(status)) {
        JS_FreeValue(ctx, result);
        return JS_ThrowPlainError(ctx, "intlDateTimeResolve: pattern build "
                                       "failed (%d)",
                                  status);
    }

    // Calendar type, mapped from ICU's name to the BCP-47 keyword value.
    std::string calendar = "gregory";
    {
        std::vector<UChar> zone = toUChars(resolvedZone);
        UErrorCode calStatus = U_ZERO_ERROR;
        UCalendar *cal = ucal_open(zone.empty() ? nullptr : zone.data(),
                                   static_cast<int32_t>(zone.size()),
                                   icuLocale.c_str(), UCAL_DEFAULT, &calStatus);
        if (U_SUCCESS(calStatus)) {
            const char *type = ucal_getType(cal, &calStatus);
            if (U_SUCCESS(calStatus) && type != nullptr) {
                calendar = (std::string(type) == "gregorian") ? "gregory"
                                                              : type;
            }
        }
        if (cal != nullptr) {
            ucal_close(cal);
        }
    }

    std::string numberingSystem = numberingSystemName(icuLocale);

    const char *hourCycle =
        hourCycleFromPattern(patternBuffer.data(), patternLength);

    JS_SetPropertyStr(ctx, result, "ok", JS_NewBool(ctx, true));
    JS_SetPropertyStr(ctx, result, "locale",
                      JS_NewString(ctx, canonicalLanguageTag(icuLocale).c_str()));
    JS_SetPropertyStr(ctx, result, "calendar",
                      JS_NewString(ctx, calendar.c_str()));
    JS_SetPropertyStr(ctx, result, "numberingSystem",
                      JS_NewString(ctx, numberingSystem.c_str()));
    JS_SetPropertyStr(ctx, result, "timeZone",
                      JS_NewString(ctx, resolvedZone.c_str()));
    if (hourCycle != nullptr) {
        JS_SetPropertyStr(ctx, result, "hourCycle",
                          JS_NewString(ctx, hourCycle));
    }
    JS_SetPropertyStr(
        ctx, result, "pattern",
        JS_NewStringUTF16(ctx,
                          reinterpret_cast<const uint16_t *>(
                              patternBuffer.data()),
                          static_cast<size_t>(patternLength)));
    return result;
}

JSValue JsEngineHost::nativeIntlDateTimeFormat(JSContext *ctx,
                                               JSValueConst thisVal, int argc,
                                               JSValueConst *argv) {
    (void)thisVal;
    if (argc < 4) {
        return JS_ThrowTypeError(ctx, "intlDateTimeFormat: expected 4 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    size_t patternLength = 0;
    const uint16_t *pattern = JS_ToCStringLenUTF16(ctx, &patternLength, argv[1]);
    if (pattern == nullptr) {
        return JS_EXCEPTION;
    }
    std::string timeZone = qjs::toString(ctx, argv[2]);
    double epochMs = 0;
    JS_ToFloat64(ctx, &epochMs, argv[3]);

    int error = U_ZERO_ERROR;
    UDateFormat *formatter = dateFormatter(
        hostOf(ctx)->intlCache(), localeTag, timeZone,
        reinterpret_cast<const UChar *>(pattern),
        static_cast<int32_t>(patternLength), &error);
    JS_FreeCStringUTF16(ctx, pattern);
    if (formatter == nullptr) {
        return JS_ThrowPlainError(ctx, "intlDateTimeFormat: ICU open failed "
                                       "(%d)",
                                  error);
    }

    UErrorCode status = U_ZERO_ERROR;
    std::vector<UChar> output(128);
    int32_t length = udat_format(formatter, epochMs, output.data(),
                                 static_cast<int32_t>(output.size()), nullptr,
                                 &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        output.resize(length);
        status = U_ZERO_ERROR;
        length = udat_format(formatter, epochMs, output.data(),
                             static_cast<int32_t>(output.size()), nullptr,
                             &status);
    }
    if (U_FAILURE(status)) {
        return JS_ThrowPlainError(ctx, "intlDateTimeFormat: format failed (%d)",
                                  status);
    }
    return JS_NewStringUTF16(ctx,
                             reinterpret_cast<const uint16_t *>(output.data()),
                             static_cast<size_t>(length));
}

JSValue JsEngineHost::nativeIntlDateTimeFormatToParts(JSContext *ctx,
                                                      JSValueConst thisVal,
                                                      int argc,
                                                      JSValueConst *argv) {
    (void)thisVal;
    if (argc < 4) {
        return JS_ThrowTypeError(ctx, "intlDateTimeFormatToParts: expected 4 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    size_t patternLength = 0;
    const uint16_t *pattern = JS_ToCStringLenUTF16(ctx, &patternLength, argv[1]);
    if (pattern == nullptr) {
        return JS_EXCEPTION;
    }
    std::string timeZone = qjs::toString(ctx, argv[2]);
    double epochMs = 0;
    JS_ToFloat64(ctx, &epochMs, argv[3]);

    int error = U_ZERO_ERROR;
    UDateFormat *formatter = dateFormatter(
        hostOf(ctx)->intlCache(), localeTag, timeZone,
        reinterpret_cast<const UChar *>(pattern),
        static_cast<int32_t>(patternLength), &error);
    JS_FreeCStringUTF16(ctx, pattern);
    if (formatter == nullptr) {
        return JS_ThrowPlainError(ctx, "intlDateTimeFormatToParts: ICU open "
                                       "failed (%d)",
                                  error);
    }

    UErrorCode status = U_ZERO_ERROR;
    UFieldPositionIterator *fields = ufieldpositer_open(&status);
    if (U_FAILURE(status)) {
        return JS_ThrowPlainError(ctx, "intlDateTimeFormatToParts: field "
                                       "iterator failed (%d)",
                                  status);
    }
    std::vector<UChar> output(128);
    int32_t length = udat_formatForFields(formatter, epochMs, output.data(),
                                          static_cast<int32_t>(output.size()),
                                          fields, &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        output.resize(length);
        ufieldpositer_close(fields);
        status = U_ZERO_ERROR;
        fields = ufieldpositer_open(&status);
        length = udat_formatForFields(formatter, epochMs, output.data(),
                                      static_cast<int32_t>(output.size()),
                                      fields, &status);
    }
    if (U_FAILURE(status)) {
        ufieldpositer_close(fields);
        return JS_ThrowPlainError(ctx, "intlDateTimeFormatToParts: format "
                                       "failed (%d)",
                                  status);
    }

    // Fields arrive in document order and do not overlap for date patterns;
    // the gaps between them are ECMA-402 "literal" parts.
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    int32_t cursor = 0;
    int32_t begin = 0;
    int32_t end = 0;
    for (int32_t field = ufieldpositer_next(fields, &begin, &end); field >= 0;
         field = ufieldpositer_next(fields, &begin, &end)) {
        if (begin > cursor) {
            pushPart(ctx, array, index++, "literal", output.data(), cursor,
                     begin);
        }
        pushPart(ctx, array, index++, dateFieldType(field), output.data(),
                 begin, end);
        cursor = end;
    }
    if (cursor < length) {
        pushPart(ctx, array, index++, "literal", output.data(), cursor, length);
    }
    ufieldpositer_close(fields);
    return array;
}

JSValue JsEngineHost::nativeIntlResolveLocale(JSContext *ctx,
                                              JSValueConst thisVal, int argc,
                                              JSValueConst *argv) {
    (void)thisVal;
    std::string localeTag = argc > 0 ? qjs::toString(ctx, argv[0]) : std::string();
    std::string icuLocale = toIcuLocale(localeTag);
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "locale",
                      JS_NewString(ctx, canonicalLanguageTag(icuLocale).c_str()));
    JS_SetPropertyStr(ctx, result, "numberingSystem",
                      JS_NewString(ctx, numberingSystemName(icuLocale).c_str()));
    return result;
}

JSValue JsEngineHost::nativeIntlNumberFormat(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv) {
    (void)thisVal;
    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "intlNumberFormat: expected 3 arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    size_t skeletonLength = 0;
    const uint16_t *skeleton =
        JS_ToCStringLenUTF16(ctx, &skeletonLength, argv[1]);
    if (skeleton == nullptr) {
        return JS_EXCEPTION;
    }
    // The number arrives as a decimal string to keep BigInt/large-int
    // precision that a double round-trip would lose.
    std::string number = qjs::toString(ctx, argv[2]);

    int error = U_ZERO_ERROR;
    UNumberFormatter *formatter = numberFormatter(
        hostOf(ctx)->intlCache(), localeTag,
        reinterpret_cast<const UChar *>(skeleton),
        static_cast<int32_t>(skeletonLength), &error);
    JS_FreeCStringUTF16(ctx, skeleton);
    if (formatter == nullptr) {
        return JS_ThrowPlainError(ctx, "intlNumberFormat: ICU open failed (%d)",
                                  error);
    }

    UErrorCode status = U_ZERO_ERROR;
    UFormattedNumber *result = unumf_openResult(&status);
    unumf_formatDecimal(formatter, number.c_str(),
                        static_cast<int32_t>(number.size()), result, &status);
    std::vector<UChar> output(128);
    int32_t length = unumf_resultToString(result, output.data(),
                                          static_cast<int32_t>(output.size()),
                                          &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        output.resize(length);
        status = U_ZERO_ERROR;
        length = unumf_resultToString(result, output.data(),
                                      static_cast<int32_t>(output.size()),
                                      &status);
    }
    unumf_closeResult(result);
    if (U_FAILURE(status)) {
        return JS_ThrowPlainError(ctx, "intlNumberFormat: format failed (%d)",
                                  status);
    }
    return JS_NewStringUTF16(ctx,
                             reinterpret_cast<const uint16_t *>(output.data()),
                             static_cast<size_t>(length));
}

JSValue JsEngineHost::nativeIntlNumberFormatToParts(JSContext *ctx,
                                                    JSValueConst thisVal,
                                                    int argc,
                                                    JSValueConst *argv) {
    (void)thisVal;
    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "intlNumberFormatToParts: expected 3 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    size_t skeletonLength = 0;
    const uint16_t *skeleton =
        JS_ToCStringLenUTF16(ctx, &skeletonLength, argv[1]);
    if (skeleton == nullptr) {
        return JS_EXCEPTION;
    }
    std::string number = qjs::toString(ctx, argv[2]);

    int error = U_ZERO_ERROR;
    UNumberFormatter *formatter = numberFormatter(
        hostOf(ctx)->intlCache(), localeTag,
        reinterpret_cast<const UChar *>(skeleton),
        static_cast<int32_t>(skeletonLength), &error);
    JS_FreeCStringUTF16(ctx, skeleton);
    if (formatter == nullptr) {
        return JS_ThrowPlainError(ctx, "intlNumberFormatToParts: ICU open "
                                       "failed (%d)",
                                  error);
    }

    UErrorCode status = U_ZERO_ERROR;
    UFormattedNumber *result = unumf_openResult(&status);
    unumf_formatDecimal(formatter, number.c_str(),
                        static_cast<int32_t>(number.size()), result, &status);
    std::vector<UChar> output(128);
    int32_t length = unumf_resultToString(result, output.data(),
                                          static_cast<int32_t>(output.size()),
                                          &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        output.resize(length);
        status = U_ZERO_ERROR;
        length = unumf_resultToString(result, output.data(),
                                      static_cast<int32_t>(output.size()),
                                      &status);
    }
    if (U_FAILURE(status)) {
        unumf_closeResult(result);
        return JS_ThrowPlainError(ctx, "intlNumberFormatToParts: format failed "
                                       "(%d)",
                                  status);
    }

    UFieldPositionIterator *fields = ufieldpositer_open(&status);
    if (U_SUCCESS(status)) {
        unumf_resultGetAllFieldPositions(result, fields, &status);
    }
    struct Field {
        int32_t field;
        int32_t begin;
        int32_t end;
    };
    std::vector<Field> collected;
    int32_t begin = 0;
    int32_t end = 0;
    for (int32_t field = ufieldpositer_next(fields, &begin, &end); field >= 0;
         field = ufieldpositer_next(fields, &begin, &end)) {
        collected.push_back({field, begin, end});
    }
    ufieldpositer_close(fields);
    unumf_closeResult(result);

    // Paint a per-character type map: containers first, then the separators
    // and symbols nested inside them, so the inner runs win the overlap. Gaps
    // stay "literal".
    std::vector<std::string> charType(length, "literal");
    for (const auto &f : collected) {
        if (!isNumberContainer(f.field)) {
            continue;
        }
        const char *type = numberFieldType(f.field, output[f.begin]);
        for (int32_t i = f.begin; i < f.end; i++) {
            charType[i] = type;
        }
    }
    for (const auto &f : collected) {
        if (isNumberContainer(f.field)) {
            continue;
        }
        const char *type = numberFieldType(f.field, output[f.begin]);
        for (int32_t i = f.begin; i < f.end; i++) {
            charType[i] = type;
        }
    }

    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    int32_t cursor = 0;
    while (cursor < length) {
        int32_t run = cursor + 1;
        while (run < length && charType[run] == charType[cursor]) {
            run++;
        }
        pushPart(ctx, array, index++, charType[cursor].c_str(), output.data(),
                 cursor, run);
        cursor = run;
    }
    return array;
}

JSValue JsEngineHost::nativeIntlPluralSelect(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv) {
    (void)thisVal;
    if (argc < 4) {
        return JS_ThrowTypeError(ctx, "intlPluralSelect: expected 4 arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    int32_t type = 0;
    JS_ToInt32(ctx, &type, argv[1]);
    size_t skeletonLength = 0;
    const uint16_t *skeleton =
        JS_ToCStringLenUTF16(ctx, &skeletonLength, argv[2]);
    if (skeleton == nullptr) {
        return JS_EXCEPTION;
    }
    std::string number = qjs::toString(ctx, argv[3]);

    IntlCache &cache = hostOf(ctx)->intlCache();
    int error = U_ZERO_ERROR;
    UNumberFormatter *formatter = numberFormatter(
        cache, localeTag, reinterpret_cast<const UChar *>(skeleton),
        static_cast<int32_t>(skeletonLength), &error);
    JS_FreeCStringUTF16(ctx, skeleton);
    if (formatter == nullptr) {
        return JS_ThrowPlainError(ctx, "intlPluralSelect: number open failed "
                                       "(%d)",
                                  error);
    }
    UPluralRules *rules = pluralRules(cache, localeTag, type, &error);
    if (rules == nullptr) {
        return JS_ThrowPlainError(ctx, "intlPluralSelect: rules open failed "
                                       "(%d)",
                                  error);
    }

    // Select against the formatted number so min/max fraction digits shape the
    // operands (e.g. "1.0" selects differently from "1").
    UErrorCode status = U_ZERO_ERROR;
    UFormattedNumber *result = unumf_openResult(&status);
    unumf_formatDecimal(formatter, number.c_str(),
                        static_cast<int32_t>(number.size()), result, &status);
    UChar keyword[64];
    int32_t length = uplrules_selectFormatted(rules, result, keyword,
                                              sizeof(keyword) / sizeof(UChar),
                                              &status);
    unumf_closeResult(result);
    if (U_FAILURE(status)) {
        return JS_ThrowPlainError(ctx, "intlPluralSelect: select failed (%d)",
                                  status);
    }
    return JS_NewStringUTF16(ctx,
                             reinterpret_cast<const uint16_t *>(keyword),
                             static_cast<size_t>(length));
}

JSValue JsEngineHost::nativeIntlPluralCategories(JSContext *ctx,
                                                 JSValueConst thisVal, int argc,
                                                 JSValueConst *argv) {
    (void)thisVal;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "intlPluralCategories: expected 2 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    int32_t type = 0;
    JS_ToInt32(ctx, &type, argv[1]);

    int error = U_ZERO_ERROR;
    UPluralRules *rules =
        pluralRules(hostOf(ctx)->intlCache(), localeTag, type, &error);
    if (rules == nullptr) {
        return JS_ThrowPlainError(ctx, "intlPluralCategories: rules open "
                                       "failed (%d)",
                                  error);
    }

    UErrorCode status = U_ZERO_ERROR;
    UEnumeration *keywords = uplrules_getKeywords(rules, &status);
    if (U_FAILURE(status)) {
        return JS_NewArray(ctx);
    }
    // Snapshot the keyword strings while the cached rules/enumeration are live,
    // then build the array: JS_SetPropertyUint32 can run a tampered-prototype
    // setter whose re-entrancy could evict and close `rules` under the handle
    // cap, so the ICU handles must not be touched once JS may run.
    std::vector<std::string> categories;
    for (;;) {
        int32_t length = 0;
        const char *keyword = uenum_next(keywords, &length, &status);
        if (keyword == nullptr || U_FAILURE(status)) {
            break;
        }
        categories.emplace_back(keyword, static_cast<size_t>(length));
    }
    uenum_close(keywords);

    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    for (const auto &category : categories) {
        JS_SetPropertyUint32(ctx, array, index++,
                             JS_NewStringLen(ctx, category.c_str(),
                                             category.size()));
    }
    return array;
}

JSValue JsEngineHost::nativeIntlCollatorCompare(JSContext *ctx,
                                                JSValueConst thisVal, int argc,
                                                JSValueConst *argv) {
    (void)thisVal;
    if (argc < 4) {
        return JS_ThrowTypeError(ctx, "intlCollatorCompare: expected 4 "
                                      "arguments");
    }
    std::string localeTag = qjs::toString(ctx, argv[0]);
    std::string signature = qjs::toString(ctx, argv[1]);

    // Coerce both operands to owned buffers BEFORE acquiring the cached
    // collator. JS_ToCStringLenUTF16 can run engine toString/valueOf, which
    // could re-enter Intl and evict (close) the very collator we would hold;
    // acquiring last means no engine JS runs while `coll` is live.
    size_t leftLength = 0;
    size_t rightLength = 0;
    const uint16_t *left = JS_ToCStringLenUTF16(ctx, &leftLength, argv[2]);
    if (left == nullptr) {
        return JS_EXCEPTION;
    }
    const uint16_t *right = JS_ToCStringLenUTF16(ctx, &rightLength, argv[3]);
    if (right == nullptr) {
        JS_FreeCStringUTF16(ctx, left);
        return JS_EXCEPTION;
    }

    int error = U_ZERO_ERROR;
    UCollator *coll =
        collator(hostOf(ctx)->intlCache(), localeTag, signature, &error);
    if (coll == nullptr) {
        JS_FreeCStringUTF16(ctx, left);
        JS_FreeCStringUTF16(ctx, right);
        return JS_ThrowPlainError(ctx, "intlCollatorCompare: ICU open failed "
                                       "(%d)",
                                  error);
    }

    UCollationResult order = ucol_strcoll(
        coll, reinterpret_cast<const UChar *>(left),
        static_cast<int32_t>(leftLength), reinterpret_cast<const UChar *>(right),
        static_cast<int32_t>(rightLength));
    JS_FreeCStringUTF16(ctx, left);
    JS_FreeCStringUTF16(ctx, right);
    return JS_NewInt32(ctx, order);
}

} // namespace macishtype
