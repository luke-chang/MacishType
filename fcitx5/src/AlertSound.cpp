#include "AlertSound.h"

#include <cstdint>
#include <memory>
#include <type_traits>
#include <utility>

#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/library.h>

#include "Log.h"

namespace MacishType::Fcitx5 {

namespace {

// libcanberra handle types; canberra.h is never included.
struct CaContext;
struct CaProplist;

// The _full entry points take a proplist; their variadic siblings cannot be
// called safely through a dlsym'd pointer.
using ContextCreate = int (*)(CaContext **);
using ContextDestroy = int (*)(CaContext *);
using FinishCallback = void (*)(CaContext *, uint32_t, int, void *);
using ContextPlayFull = int (*)(CaContext *, uint32_t, CaProplist *,
                                FinishCallback, void *);
using ProplistCreate = int (*)(CaProplist **);
using ProplistDestroy = int (*)(CaProplist *);
using ProplistSets = int (*)(CaProplist *, const char *, const char *);

constexpr const char *kSoname = "libcanberra.so.0";
// freedesktop sound naming spec property key.
constexpr const char *kEventIdKey = "event.id";

template <typename Fn>
bool resolve(fcitx::Library &library, const char *name, Fn &slot) {
    slot = fcitx::Library::toFunction<std::remove_pointer_t<Fn>>(
        library.resolve(name));
    return slot != nullptr;
}

struct Canberra {
    // Loaded with fcitx's default hint, which keeps the library mapped: it
    // may still own a sound-server connection thread.
    fcitx::Library handle{kSoname};
    CaContext *context = nullptr;
    ContextDestroy contextDestroy = nullptr;
    ContextPlayFull contextPlayFull = nullptr;
    ProplistCreate proplistCreate = nullptr;
    ProplistDestroy proplistDestroy = nullptr;
    ProplistSets proplistSets = nullptr;

    ~Canberra() {
        if (context != nullptr && contextDestroy != nullptr) {
            contextDestroy(context);
        }
    }

    void play(const std::string &eventId) {
        CaProplist *props = nullptr;
        if (proplistCreate(&props) != 0 || props == nullptr) {
            return;
        }
        proplistSets(props, kEventIdKey, eventId.c_str());
        // Id 0: nothing cancels a cue, so it needs no handle. A refused
        // playback goes unreported — the contract never promises the sound
        // is heard.
        contextPlayFull(context, 0, props, nullptr, nullptr);
        proplistDestroy(props);
    }
};

// Worker thread only. Returns null after reporting why there will be no
// sound; fcitx's log stream is replaceable and therefore not guaranteed
// thread-safe, so the message is printed back on the event loop.
std::unique_ptr<Canberra> loadCanberra(fcitx::EventDispatcher *dispatcher) {
    auto report = [dispatcher](std::string message) {
        dispatcher->schedule(
            [message = std::move(message)] { MACISHTYPE_INFO() << message; });
    };

    auto canberra = std::make_unique<Canberra>();
    if (!canberra->handle.load()) {
        report(std::string("alert sounds unavailable: ") + kSoname + ": " +
               canberra->handle.error());
        return nullptr;
    }

    ContextCreate create = nullptr;
    if (!resolve(canberra->handle, "ca_context_create", create) ||
        !resolve(canberra->handle, "ca_context_destroy",
                 canberra->contextDestroy) ||
        !resolve(canberra->handle, "ca_context_play_full",
                 canberra->contextPlayFull) ||
        !resolve(canberra->handle, "ca_proplist_create",
                 canberra->proplistCreate) ||
        !resolve(canberra->handle, "ca_proplist_destroy",
                 canberra->proplistDestroy) ||
        !resolve(canberra->handle, "ca_proplist_sets",
                 canberra->proplistSets)) {
        report(std::string("alert sounds unavailable: ") + kSoname +
               " lacks an expected symbol");
        return nullptr;
    }
    if (create(&canberra->context) != 0 || canberra->context == nullptr) {
        report(std::string("alert sounds unavailable: could not open a ") +
               kSoname + " context");
        return nullptr;
    }
    return canberra;
}

} // namespace

AlertSound::~AlertSound() {
    if (!worker_.joinable()) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    wake_.notify_one();
    worker_.join();
}

void AlertSound::setEventId(std::string id) {
    std::lock_guard<std::mutex> lock(mutex_);
    eventId_ = id == "none" ? std::string() : std::move(id);
}

void AlertSound::play() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (eventId_.empty()) {
            return;
        }
        pending_ = true;
    }
    if (!worker_.joinable()) {
        worker_ = std::thread([this] { workerMain(); });
    }
    wake_.notify_one();
}

void AlertSound::workerMain() {
    // Owned by this thread for its whole lifetime: libcanberra's context has
    // to be closed on the thread that opened it.
    std::unique_ptr<Canberra> canberra = loadCanberra(dispatcher_);
    while (canberra) {
        std::string eventId;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return pending_ || stopping_; });
            if (stopping_) {
                break;
            }
            // Taken before playing, so requests arriving during playback set
            // it again and collapse into one follow-up cue.
            pending_ = false;
            eventId = eventId_;
        }
        if (!eventId.empty()) {
            canberra->play(eventId);
        }
    }
}

} // namespace MacishType::Fcitx5
