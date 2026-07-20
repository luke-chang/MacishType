#include "intl.h"

#include <cstdint>
#include <string>

#include <fcitx-utils/macros.h>

#include "enginehost.h"
#include "intl_icu.h"
#include "qjsutil.h"

namespace macishtype {

// Closes every cached ICU handle. The maps are populated by the get-or-open
// helpers below; the maps not yet driven by any helper stay empty until later
// phases, but their close calls also anchor the ICU link.
IntlCache::~IntlCache() {
    for (auto &[key, handle] : breakIterators_) {
        ubrk_close(static_cast<UBreakIterator *>(handle));
    }
    for (auto &[key, handle] : dateFormatters_) {
        udat_close(static_cast<UDateFormat *>(handle));
    }
    for (auto &[key, handle] : numberFormatters_) {
        unumf_close(static_cast<UNumberFormatter *>(handle));
    }
    for (auto &[key, handle] : collators_) {
        ucol_close(static_cast<UCollator *>(handle));
    }
    for (auto &[key, handle] : pluralRules_) {
        uplrules_close(static_cast<UPluralRules *>(handle));
    }
}

void *IntlCache::breakIterator(int type, const std::string &locale,
                               int *status) {
    std::string key = std::to_string(type) + "|" + locale;
    auto existing = breakIterators_.find(key);
    if (existing != breakIterators_.end()) {
        return existing->second;
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
    breakIterators_[key] = iterator;
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
// tag degrades to ICU's own locale fallback rather than an error.
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

} // namespace

JSValue JsEngineHost::nativeIntlSegment(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
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

    // boundaries[i]..boundaries[i+1] spans segment i; for the whole string it
    // runs [0, …, length], so the segment count is boundaries.length - 1.
    JSValue boundaries = JS_NewArray(ctx);
    JSValue wordLike = (type == UBRK_WORD) ? JS_NewArray(ctx) : JS_UNDEFINED;
    uint32_t boundaryIndex = 0;
    uint32_t wordLikeIndex = 0;

    int32_t position = ubrk_first(iterator);
    JS_SetPropertyUint32(ctx, boundaries, boundaryIndex++,
                         JS_NewInt32(ctx, position));
    for (int32_t next = ubrk_next(iterator); next != UBRK_DONE;
         next = ubrk_next(iterator)) {
        JS_SetPropertyUint32(ctx, boundaries, boundaryIndex++,
                             JS_NewInt32(ctx, next));
        if (type == UBRK_WORD) {
            // A rule status in the UBRK_WORD_NONE range marks whitespace and
            // punctuation runs; anything else (letters, numbers, kana, …) is
            // word-like, per ECMA-402's isWordLike.
            int32_t rule = ubrk_getRuleStatus(iterator);
            bool isWordLike =
                !(rule >= UBRK_WORD_NONE && rule < UBRK_WORD_NONE_LIMIT);
            JS_SetPropertyUint32(ctx, wordLike, wordLikeIndex++,
                                 JS_NewBool(ctx, isWordLike));
        }
    }

    JS_FreeCStringUTF16(ctx, text);

    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "boundaries", boundaries);
    if (type == UBRK_WORD) {
        JS_SetPropertyStr(ctx, result, "wordLike", wordLike);
    }
    return result;
}

} // namespace macishtype
