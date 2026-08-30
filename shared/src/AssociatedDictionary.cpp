#include "MacishType/AssociatedDictionary.h"

#include <cstdint>
#include <fstream>
#include <sstream>

#include "MacishType/Log.h"
#include "MacishType/Utf8.h"

namespace MacishType {
namespace {

AssociatedDictionary::Entries parseTable(const std::filesystem::path &path) {
    AssociatedDictionary::Entries entries;
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        MACISHTYPE_FAULT() << "Associated dictionary could not be read: "
                           << path.string();
        return entries;
    }
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
            entries[key] = std::move(followups);
        }
    }
    MACISHTYPE_INFO() << path.stem().string() << ": " << entries.size()
                      << " prefixes";
    return entries;
}

RefCountedDictionary<AssociatedDictionary::Entries> &store() {
    static RefCountedDictionary<AssociatedDictionary::Entries> instance(
        parseTable);
    return instance;
}

} // namespace

AssociatedDictionary::Handle
AssociatedDictionary::acquire(const std::filesystem::path &path) {
    return Handle(store().acquire(path));
}

std::vector<std::string>
AssociatedDictionary::Handle::followups(IntlCache &cache,
                                        const std::string &heldText) const {
    if (!inner_ || heldText.empty() ||
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
    const Entries &entries = inner_.value();
    auto found =
        entries.find(heldText.substr(boundaries[boundaries.size() - 2]));
    return found != entries.end() ? found->second : std::vector<std::string>{};
}

} // namespace MacishType
