#pragma once

#include <filesystem>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "MacishType/Intl.h"
#include "MacishType/RefCountedDictionary.h"

namespace MacishType {

// Leading grapheme cluster -> following phrases, parsed from the shared
// AssociatedDictionary.<language>.txt table. Every handle acquired for the
// same path shares one parsed copy, which is released once the last handle
// drops.
//
// The path is resolved by the caller so this stays free of any host seam:
// where the table lives is a host question, and a native host can acquire one
// without installing host services.
class AssociatedDictionary {
public:
    using Entries = std::map<std::string, std::vector<std::string>>;

    // Move-only RAII reference to the loaded table. A default-constructed
    // handle is empty and answers every lookup with no follow-ups.
    class Handle {
    public:
        Handle() = default;

        explicit operator bool() const { return static_cast<bool>(inner_); }
        void reset() { inner_.reset(); }

        // Follow-ups for the last grapheme cluster of `heldText`. Empty when
        // this handle is unset, when the text is not valid UTF-8 or has no
        // clusters, or when the table has no entry for that cluster.
        std::vector<std::string> followups(IntlCache &cache,
                                           const std::string &heldText) const;

    private:
        friend class AssociatedDictionary;

        explicit Handle(RefCountedDictionary<Entries>::Handle inner)
            : inner_(std::move(inner)) {}

        RefCountedDictionary<Entries>::Handle inner_;
    };

    // An empty path yields an empty handle.
    static Handle acquire(const std::filesystem::path &path);
};

} // namespace MacishType
