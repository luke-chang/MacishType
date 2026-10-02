#pragma once

#include <string>

namespace MacishType::Fcitx5 {

// Engine keys are free-form under the contract, but fcitx's ini writer
// escapes only values, its reader trims each line, and '/' nests a
// RawConfig path; the bytes that would break are percent-encoded.
std::string encodeOptionName(const std::string &key);
std::string decodeOptionName(const std::string &name);

} // namespace MacishType::Fcitx5
