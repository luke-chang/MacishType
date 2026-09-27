#include "MacishType/LanguageTag.h"

#include <algorithm>
#include <cctype>

#include "MacishType/IntlIcu.h"

namespace MacishType {

namespace {

bool equalIgnoringCase(std::string_view left, std::string_view right) {
    return left.size() == right.size() &&
           std::equal(left.begin(), left.end(), right.begin(),
                      [](unsigned char lhs, unsigned char rhs) {
                          return std::tolower(lhs) == std::tolower(rhs);
                      });
}

} // namespace

std::string likelyScript(const std::string &tag) {
    // Each step must succeed outright: a warning means an unterminated
    // buffer, and a tag ICU reads only in part would maximize as the empty
    // locale, en_Latn_US.
    char icuLocale[ULOC_FULLNAME_CAPACITY];
    char likely[ULOC_FULLNAME_CAPACITY];
    char script[ULOC_SCRIPT_CAPACITY];
    UErrorCode status = U_ZERO_ERROR;
    int32_t parsed = 0;
    int32_t length = uloc_forLanguageTag(tag.c_str(), icuLocale,
                                         sizeof(icuLocale), &parsed, &status);
    if (status != U_ZERO_ERROR || length <= 0 ||
        parsed != static_cast<int32_t>(tag.size())) {
        return {};
    }
    uloc_addLikelySubtags(icuLocale, likely, sizeof(likely), &status);
    if (status != U_ZERO_ERROR) {
        return {};
    }
    length = uloc_getScript(likely, script, sizeof(script), &status);
    if (status != U_ZERO_ERROR) {
        return {};
    }
    return std::string(script, length);
}

std::string withoutRedundantScript(std::string_view tag) {
    size_t first = tag.find('-');
    if (first == std::string_view::npos) {
        return std::string(tag);
    }
    size_t second = std::min(tag.find('-', first + 1), tag.size());
    std::string_view script = tag.substr(first + 1, second - first - 1);
    // A four-character variant (de-1996) never matches a likely script.
    if (script.size() != 4) {
        return std::string(tag);
    }
    std::string rest =
        std::string(tag.substr(0, first)).append(tag.substr(second));
    return equalIgnoringCase(likelyScript(rest), script) ? rest
                                                         : std::string(tag);
}

} // namespace MacishType
