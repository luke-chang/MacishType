#include "enginewatcher.h"

#include <sys/inotify.h>
#include <unistd.h>

#include <system_error>
#include <vector>

#include "log.h"

namespace macishtype {

namespace {

constexpr uint64_t kDebounceMicroseconds = 300 * 1000;
constexpr uint32_t kWatchMask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM |
                                IN_CREATE | IN_DELETE | IN_DONT_FOLLOW;

bool isNoiseName(const std::string &name) {
    if (name.empty() || name[0] == '.') {
        return true;
    }
    if (name.back() == '~') {
        return true;
    }
    // Engine-private persistence; its traffic feeds storage events, not
    // reloads.
    return name == "_storage";
}

} // namespace

EngineWatcher::EngineWatcher(fcitx::EventLoop *eventLoop, Callback callback,
                             Callback storageCallback)
    : eventLoop_(eventLoop), callback_(std::move(callback)),
      storageCallback_(std::move(storageCallback)) {
    inotifyFd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (inotifyFd_ < 0) {
        MACISHTYPE_WARN() << "inotify unavailable; hot reload disabled";
        return;
    }
    ioSource_ = eventLoop_->addIOEvent(
        inotifyFd_, fcitx::IOEventFlag::In,
        [this](fcitx::EventSourceIO *, int, fcitx::IOEventFlags) {
            handleEvents();
            return true;
        });
}

EngineWatcher::~EngineWatcher() {
    ioSource_.reset();
    if (inotifyFd_ >= 0) {
        close(inotifyFd_);
    }
}

void EngineWatcher::watchEngine(const std::string &engineId,
                                const std::filesystem::path &root) {
    if (inotifyFd_ < 0) {
        return;
    }
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    if (errorCode) {
        return;
    }
    watchDirectoryTree(engineId, canonicalRoot);
}

void EngineWatcher::watchStorage(const std::string &engineId,
                                 const std::filesystem::path &directory) {
    if (inotifyFd_ < 0) {
        return;
    }
    std::error_code errorCode;
    std::filesystem::create_directories(directory, errorCode);
    int descriptor =
        inotify_add_watch(inotifyFd_, directory.c_str(), kWatchMask);
    if (descriptor < 0) {
        MACISHTYPE_WARN() << "Cannot watch storage directory " << directory;
        return;
    }
    watches_[descriptor] = {engineId, directory, true};
    storageWatchDescriptors_[engineId] = descriptor;
}

void EngineWatcher::unwatchStorage(const std::string &engineId) {
    auto found = storageWatchDescriptors_.find(engineId);
    if (found == storageWatchDescriptors_.end()) {
        return;
    }
    inotify_rm_watch(inotifyFd_, found->second);
    watches_.erase(found->second);
    storageWatchDescriptors_.erase(found);
}

void EngineWatcher::watchDirectoryTree(
    const std::string &engineId, const std::filesystem::path &directory) {
    int descriptor =
        inotify_add_watch(inotifyFd_, directory.c_str(), kWatchMask);
    if (descriptor < 0) {
        return;
    }
    // inotify reuses the descriptor when the directory is already watched.
    watches_[descriptor] = {engineId, directory, false};

    std::error_code errorCode;
    std::filesystem::directory_iterator iterator(directory, errorCode);
    if (errorCode) {
        return;
    }
    for (const auto &entry : iterator) {
        // Never follow a symlink: a bundled directory symlink could escape the
        // engine folder (exhausting the inotify budget) or point back inside
        // it and recurse forever. Only real subdirectories are watched.
        if (entry.is_symlink(errorCode)) {
            continue;
        }
        if (entry.is_directory(errorCode) &&
            !isNoiseName(entry.path().filename().string())) {
            watchDirectoryTree(engineId, entry.path());
        }
    }
}

void EngineWatcher::handleEvents() {
    alignas(inotify_event) char buffer[4096];
    for (;;) {
        ssize_t length = read(inotifyFd_, buffer, sizeof(buffer));
        if (length <= 0) {
            return;
        }
        ssize_t offset = 0;
        while (offset < length) {
            const auto *event =
                reinterpret_cast<const inotify_event *>(buffer + offset);
            offset += sizeof(inotify_event) + event->len;

            auto watch = watches_.find(event->wd);
            if (watch == watches_.end()) {
                continue;
            }
            std::string name = event->len > 0 ? event->name : "";
            if (isNoiseName(name)) {
                continue;
            }
            const auto &[engineId, directory, storage] = watch->second;
            // A new subdirectory (e.g. unpacked data) joins the watch set.
            if (!storage && (event->mask & IN_CREATE) &&
                (event->mask & IN_ISDIR)) {
                watchDirectoryTree(engineId, directory / name);
            }
            scheduleCallback(engineId, directory / name, storage);
        }
    }
}

void EngineWatcher::scheduleCallback(const std::string &engineId,
                                     const std::filesystem::path &changedPath,
                                     bool storage) {
    // Editors burst several events per save; (re)arming a one-shot timer
    // coalesces them into one callback carrying every touched path.
    std::string slot = (storage ? "storage:" : "reload:") + engineId;
    pendingPaths_[slot].insert(changedPath.string());
    pending_[slot] = eventLoop_->addTimeEvent(
        CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kDebounceMicroseconds,
        0,
        [this, engineId, slot, storage](fcitx::EventSourceTime *, uint64_t) {
            // Erasing pending_[slot] destroys the unique_ptr that owns this
            // very closure, taking its captures with it. Move everything
            // needed onto the stack first; after the erase, touch only locals
            // and the still-live EngineWatcher (reached through `self`).
            EngineWatcher *self = this;
            const bool isStorage = storage;
            std::string localEngineId = engineId;
            auto changed = std::move(self->pendingPaths_[slot]);
            self->pendingPaths_.erase(slot);
            self->pending_.erase(slot);
            (isStorage ? self->storageCallback_
                       : self->callback_)(localEngineId, changed);
            return true;
        });
}

} // namespace macishtype
