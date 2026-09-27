// The script rule behind navigator.languages. The zh, sr, and plain cases
// mirror macOS's LanguageTagTests, which reach the same CLDR data through
// Locale.Language, so the two hosts stay locked to one answer; languages
// whose likely script CLDR has moved between releases are left out.

#include <string>

#include "Checks.h"
#include "MacishType/LanguageTag.h"

using MacishType::likelyScript;
using MacishType::withoutRedundantScript;

void testLanguageTags(Checks &checks) {
    struct Case {
        const char *tag;
        const char *expected;
    };
    const Case normalized[] = {
        {"zh-Hant-TW", "zh-TW"},       {"zh-Hant-HK", "zh-HK"},
        {"zh-Hans-CN", "zh-CN"},       {"zh-Hans-SG", "zh-SG"},
        {"zh-Hans", "zh"},             {"zh-Hans-HK", "zh-Hans-HK"},
        {"zh-Hant", "zh-Hant"},        {"sr-Latn-RS", "sr-Latn-RS"},
        {"sr-Cyrl-RS", "sr-RS"},       {"uz-Cyrl-UZ", "uz-Cyrl-UZ"},
        {"en-US", "en-US"},            {"es-419", "es-419"},
        {"ja", "ja"},                  {"ca-ES-valencia", "ca-ES-valencia"},
        {"de-1996", "de-1996"},        {"ber-Latn-DZ", "ber-Latn-DZ"},
        {"a-Latn", "a-Latn"},
    };
    for (const auto &item : normalized) {
        std::string what = std::string("withoutRedundantScript(") + item.tag +
                           ") == " + item.expected;
        checks.expect(withoutRedundantScript(item.tag) == item.expected,
                      what.c_str());
    }

    const Case scripts[] = {
        {"zh-TW", "Hant"}, {"zh-HK", "Hant"},      {"zh", "Hans"},
        {"zh-SG", "Hans"}, {"zh-Hant-GB", "Hant"}, {"ber", ""},
        {"", ""},          {"zh_TW", ""},          {"a", ""},
    };
    for (const auto &item : scripts) {
        std::string what =
            std::string("likelyScript(") + item.tag + ") == " + item.expected;
        checks.expect(likelyScript(item.tag) == item.expected, what.c_str());
    }

    // Long enough that ICU's rendering of it fills the fixed buffer: an
    // answer instead of an overread.
    std::string longTag = "zh-TW-x";
    while (longTag.size() < 200) {
        longTag += "-abcdefgh";
    }
    checks.expect(likelyScript(longTag).empty(),
                  "likelyScript of an oversized tag is empty");
}
