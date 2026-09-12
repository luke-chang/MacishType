#include "MacishType/AssociatedDictionary.h"

#include <string_view>

#include "MacishType/Log.h"
#include "MacishType/TableFile.h"
#include "MacishType/Utf8.h"

namespace MacishType {
namespace {

// Everything up to and including the space is a separator, so no lead byte
// of a UTF-8 phrase can be mistaken for one.
bool isSeparator(char ch) { return static_cast<unsigned char>(ch) <= ' '; }

AssociatedDictionary::Entries parseTable(const std::filesystem::path &path) {
    AssociatedDictionary::Entries entries;
    bool read = forEachTableLine(
        path, [&entries](std::string_view key, std::string_view value) {
            std::vector<std::string> followups;
            for (size_t pos = 0; pos < value.size();) {
                size_t start = pos;
                while (pos < value.size() && !isSeparator(value[pos])) {
                    ++pos;
                }
                if (pos > start) {
                    followups.emplace_back(value.substr(start, pos - start));
                } else {
                    ++pos;
                }
            }
            if (!key.empty() && !followups.empty()) {
                entries.insert_or_assign(std::string(key),
                                         std::move(followups));
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
