#pragma once

#include <MacishType/HostSeams.h>

namespace MacishType::Fcitx5 {

// FontCoverageProvider over fontconfig: unions the charsets of every
// installed font into the shared coverage bitmap format. Falls back to
// full coverage when fontconfig fails. Computed once, cached for the
// process lifetime.
class FontconfigCoverageProvider : public ::MacishType::FontCoverageProvider {
public:
    const std::string &coverageBitmapBase64() override;
};

} // namespace MacishType::Fcitx5
