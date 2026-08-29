#include "MacishType/AssociatedDictionary.h"

#include <fstream>
#include <sstream>

#include "MacishType/Log.h"
#include "MacishType/Utf8.h"

namespace MacishType {

void AssociatedDictionary::ensureLoaded() {
    if (loaded_) {
        return;
    }
    loaded_ = true;
    if (path_.empty()) {
        return;
    }
    std::ifstream stream(path_, std::ios::binary);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }
        auto tab = line.find('\t');
        if (tab == std::string::npos) {
            continue;
        }
        std::string key = line.substr(0, tab);
        std::vector<std::string> followups;
        std::istringstream values(line.substr(tab + 1));
        std::string phrase;
        while (values >> phrase) {
            followups.push_back(phrase);
        }
        if (!key.empty() && !followups.empty()) {
            entries_[key] = std::move(followups);
        }
    }
    MACISHTYPE_INFO() << "AssociatedDictionary." << language_ << ": "
                      << entries_.size() << " prefixes";
}

std::vector<std::string>
AssociatedDictionary::followups(IntlCache &cache, const std::string &heldText) {
    ensureLoaded();
    if (heldText.empty() ||
        !isStrictUtf8(reinterpret_cast<const uint8_t *>(heldText.data()),
                      heldText.size())) {
        return {};
    }
    // Key on the last cluster: follow-ups attach after the held text, so
    // multi-character held text (staged prefix + candidate) chains off its
    // trailing character.
    auto boundaries = graphemeBoundariesUtf8(cache, heldText);
    if (boundaries.size() < 2) {
        return {};
    }
    auto found = entries_.find(heldText.substr(boundaries[boundaries.size() - 2]));
    return found != entries_.end() ? found->second : std::vector<std::string>{};
}

} // namespace MacishType
