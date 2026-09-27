#pragma once

#include <string>
#include <string_view>

namespace MacishType {

// The script CLDR's likely subtags give a BCP 47 tag; a script the tag names
// stands. Empty when ICU cannot read the whole tag or has no data for it.
std::string likelyScript(const std::string &tag);

// Web-style BCP 47 drops a script only when the rest of the tag implies it:
// zh-Hant-TW becomes zh-TW, while sr-Latn-RS and zh-Hant keep theirs.
std::string withoutRedundantScript(std::string_view tag);

} // namespace MacishType
