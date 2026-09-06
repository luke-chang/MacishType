#include "MacishType/AssociatedDictionary.h"

#include <sstream>

#include "MacishType/Log.h"
#include "MacishType/TableFile.h"
#include "MacishType/Utf8.h"

namespace MacishType {
namespace {

AssociatedDictionary::Entries parseTable(const std::filesystem::path &path) {
    AssociatedDictionary::Entries entries;
    bool read = forEachTableLine(
        path, [&entries](const std::string &key, const std::string &value) {
            std::vector<std::string> followups;
            std::istringstream values(value);
            std::string phrase;
            while (values >> phrase) {
                followups.push_back(phrase);
            }
            if (!key.empty() && !followups.empty()) {
                entries[key] = std::move(followups);
            }
        });
    if (!read) {
        MACISHTYPE_FAULT() << "Associated dictionary could not be read: "
                           << path.string();
        return entries;
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
    if (!inner_ || heldText.empty() || !isStrictUtf8(heldText)) {
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
