#include "MacishType/RefCountedDictionary.h"

#include "MacishType/Log.h"

namespace MacishType {

void RefCountedDictionaryReporter::reportAcquired(
    const std::filesystem::path &path, int count) {
    MACISHTYPE_DEBUG() << path.stem().string() << ": acquired (refcount="
                       << count << ")";
}

void RefCountedDictionaryReporter::reportReleased(
    const std::filesystem::path &path, int count) {
    if (count > 0) {
        MACISHTYPE_DEBUG() << path.stem().string() << ": released (refcount="
                           << count << ")";
        return;
    }
    // Pairs with the load line the table's parser emits, so a second load with
    // no unload between them is a sharing regression rather than a reload.
    MACISHTYPE_INFO() << path.stem().string() << ": unloaded";
}

} // namespace MacishType
