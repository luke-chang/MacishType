#pragma once

#include <filesystem>
#include <map>
#include <utility>

namespace MacishType {

// Non-template base so the refcount reporting can live in a .cpp. This header
// must stay free of the logging macros: it reaches every translation unit that
// touches a shared table, and a host with its own MACISHTYPE_* facade must not
// inherit a second definition of them.
class RefCountedDictionaryReporter {
protected:
    ~RefCountedDictionaryReporter() = default;

    // `count` is the refcount after the transition; a release to 0 is the
    // unload.
    static void reportAcquired(const std::filesystem::path &path, int count);
    static void reportReleased(const std::filesystem::path &path, int count);
};

// Path-keyed, reference-counted loader for a parsed data table. Callers
// acquire() a Handle; the first acquire for a path parses the file and the
// last release drops the parsed value, so hosts that need the same table share
// one copy.
//
// Keying on the resolved path rather than on a language keeps this free of any
// host seam: whoever knows where the table lives already holds the path, and
// two engines sharing a language resolve to the same one.
//
// Single-threaded: every call happens on the host loop thread, so there is no
// locking. A reference handed out by Handle::value() stays valid until the next
// acquire() or release() on the same registry.
template <typename Value>
class RefCountedDictionary : private RefCountedDictionaryReporter {
private:
    struct Slot {
        Value value;
        int count;
    };
    // std::map, not unordered_map: a Handle holds an iterator, so iterators
    // must survive insertion and erasure of other keys.
    using Slots = std::map<std::filesystem::path, Slot>;

public:
    // Builds the parsed value from the file at `path`, which it opens itself.
    // Owning the open is what keeps this header free of I/O and of the
    // MACISHTYPE_* macros: a parser that logs lives in a .cpp, so those macros
    // never reach the translation units that include this header.
    using Parser = Value (*)(const std::filesystem::path &);

    // Move-only RAII reference to one loaded table. A default-constructed
    // handle is empty and safe to destroy, reset, or move from.
    class Handle {
    public:
        Handle() = default;
        ~Handle() { reset(); }

        Handle(Handle &&other) noexcept
            : owner_(other.owner_), slot_(other.slot_) {
            other.owner_ = nullptr;
        }

        Handle &operator=(Handle &&other) noexcept {
            if (this != &other) {
                reset();
                owner_ = other.owner_;
                slot_ = other.slot_;
                other.owner_ = nullptr;
            }
            return *this;
        }

        Handle(const Handle &) = delete;
        Handle &operator=(const Handle &) = delete;

        explicit operator bool() const { return owner_ != nullptr; }

        // Precondition: engaged.
        const Value &value() const { return slot_->second.value; }

        void reset() {
            if (owner_ != nullptr) {
                owner_->release(slot_);
                owner_ = nullptr;
            }
        }

    private:
        friend RefCountedDictionary;

        Handle(RefCountedDictionary *owner, typename Slots::iterator slot)
            : owner_(owner), slot_(slot) {}

        RefCountedDictionary *owner_ = nullptr;
        typename Slots::iterator slot_{};
    };

    explicit RefCountedDictionary(Parser parse) : parse_(parse) {}

    RefCountedDictionary(const RefCountedDictionary &) = delete;
    RefCountedDictionary &operator=(const RefCountedDictionary &) = delete;

    // An empty path yields an empty handle: nothing is parsed and no slot is
    // created, so a caller whose host could not locate the table needs no
    // guard of its own.
    Handle acquire(const std::filesystem::path &path) {
        if (path.empty()) {
            return {};
        }
        auto slot = slots_.find(path);
        if (slot == slots_.end()) {
            // Parse before touching the map: a parser that throws must leave
            // the registry untouched rather than leave behind an empty slot
            // that the next acquire would adopt as a valid table.
            Value value = parse_(path);
            slot = slots_.emplace(path, Slot{std::move(value), 0}).first;
        }
        ++slot->second.count;
        reportAcquired(path, slot->second.count);
        return Handle(this, slot);
    }

private:
    void release(typename Slots::iterator slot) {
        // Report before erasing: the slot owns the key the report names.
        const int count = --slot->second.count;
        reportReleased(slot->first, count);
        if (count == 0) {
            slots_.erase(slot);
        }
    }

    Parser parse_;
    Slots slots_;
};

} // namespace MacishType
