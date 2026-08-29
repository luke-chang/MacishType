#pragma once

#include <filesystem>
#include <map>
#include <string>
#include <vector>

#include "MacishType/Intl.h"

namespace MacishType {

// Leading grapheme cluster -> following phrases, parsed from the shared
// AssociatedDictionary.<language>.txt table. Loads on first lookup.
//
// The path is resolved by the caller so this stays free of any host seam:
// a native host can construct one without installing host services.
class AssociatedDictionary {
public:
    AssociatedDictionary(std::filesystem::path path, std::string language)
        : path_(std::move(path)), language_(std::move(language)) {}

    // Follow-ups for the last grapheme cluster of `heldText`; empty when the
    // text is not valid UTF-8, has no clusters, or misses the table.
    std::vector<std::string> followups(IntlCache &cache,
                                       const std::string &heldText);

private:
    void ensureLoaded();

    std::filesystem::path path_;
    std::string language_;
    std::map<std::string, std::vector<std::string>> entries_;
    bool loaded_ = false;
};

} // namespace MacishType
