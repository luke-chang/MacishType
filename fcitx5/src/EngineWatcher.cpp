#include "EngineWatcher.h"

#include <sys/inotify.h>
#include <unistd.h>

#include <algorithm>
#include <string_view>
#include <system_error>
#include <vector>

#include "Log.h"
#include "OneShotTimer.h"

namespace MacishType::Fcitx5 {

namespace {

constexpr uint64_t kDebounceMicroseconds = 300 * 1000;
constexpr uint32_t kWatchMask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM |
                                IN_CREATE | IN_DELETE | IN_DONT_FOLLOW;
// A chmod raises only IN_ATTRIB, and it can make an engine file readable.
// IN_ONLYDIR (with IN_DONT_FOLLOW) refuses a directory that was replaced by a
// symlink before its event got handled.
constexpr uint32_t kEngineWatchMask = kWatchMask | IN_ATTRIB | IN_ONLYDIR;

// Engine-private persistence; its traffic feeds storage events, not reloads.
constexpr std::string_view kStorageName = "_storage";

// Dot folders such as `.git` would exhaust the inotify budget.
bool isUnwatchedDirectoryName(const std::string &name) {
    return name.empty() || name[0] == '.' || name == kStorageName;
}

// Engine files keep any name, since reloads are scoped to the files the
// engine loaded. Folder and storage-key names never start with a dot or end
// with a tilde, so those are editor droppings.
bool isIgnoredName(bool engineFile, const std::string &name) {
    if (engineFile) {
        return name.empty() || name == kStorageName;
    }
    return name.empty() || name[0] == '.' || name.back() == '~';
}

} // namespace

EngineWatcher::EngineWatcher(fcitx::EventLoop *eventLoop, Callback callback,
                             Callback storageCallback, Callback rootCallback)
    : eventLoop_(eventLoop), callback_(std::move(callback)),
      storageCallback_(std::move(storageCallback)),
      rootCallback_(std::move(rootCallback)) {
    inotifyFd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (inotifyFd_ < 0) {
        MACISHTYPE_NOTICE() << "inotify unavailable; hot reload disabled";
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
    // A storage root can move across layers at runtime (folder recovery
    // may resolve a different layer); drop any previous watch first so a
    // stale one does not keep feeding events from the old directory.
    unwatchStorage(engineId);
    int descriptor =
        inotify_add_watch(inotifyFd_, directory.c_str(), kWatchMask);
    if (descriptor < 0) {
        MACISHTYPE_NOTICE() << "Cannot watch storage directory " << directory;
        return;
    }
    watches_[descriptor] = {engineId, directory, WatchKind::Storage};
    storageWatchDescriptors_[engineId] = descriptor;
}

void EngineWatcher::watchEnginesRoot(const std::filesystem::path &directory) {
    if (inotifyFd_ < 0) {
        return;
    }
    // Resolve symlinked layers: kWatchMask carries IN_DONT_FOLLOW, and a
    // watch on the symlink inode would never see folder churn.
    std::error_code errorCode;
    auto canonicalDirectory = std::filesystem::canonical(directory, errorCode);
    if (errorCode) {
        return;
    }
    int descriptor = inotify_add_watch(inotifyFd_, canonicalDirectory.c_str(),
                                       kWatchMask);
    if (descriptor < 0) {
        MACISHTYPE_NOTICE() << "Cannot watch engines directory "
                            << canonicalDirectory;
        return;
    }
    watches_[descriptor] = {std::string(), canonicalDirectory,
                            WatchKind::Root};
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

void EngineWatcher::watchDirectoryTree(const std::string &engineId,
                                       const std::filesystem::path &directory,
                                       bool skipWatched) {
    int descriptor =
        inotify_add_watch(inotifyFd_, directory.c_str(), kEngineWatchMask);
    if (descriptor < 0) {
        return;
    }
    // inotify reuses the descriptor when the directory is already watched.
    watches_[descriptor] = {engineId, directory, WatchKind::Engine};

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
        if (!entry.is_directory(errorCode) ||
            isUnwatchedDirectoryName(entry.path().filename().string())) {
            continue;
        }
        if (skipWatched) {
            int existing = inotify_add_watch(
                inotifyFd_, entry.path().c_str(), kEngineWatchMask);
            if (existing >= 0 && watches_.count(existing) != 0) {
                continue;
            }
        }
        watchDirectoryTree(engineId, entry.path(), skipWatched);
    }
}

void EngineWatcher::unwatchDirectoryTree(
    const std::filesystem::path &directory) {
    for (auto it = watches_.begin(); it != watches_.end();) {
        const auto &watched = it->second.directory;
        auto [prefixEnd, watchedEnd] =
            std::mismatch(directory.begin(), directory.end(),
                          watched.begin(), watched.end());
        if (it->second.kind == WatchKind::Engine &&
            prefixEnd == directory.end()) {
            inotify_rm_watch(inotifyFd_, it->first);
            it = watches_.erase(it);
        } else {
            ++it;
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
            // The kernel auto-removes a watch when its directory is deleted,
            // emitting IN_IGNORED (empty name). Reclaim the bookkeeping so a
            // descriptor freed by a folder deletion cannot later be matched
            // to a reused wd (inotify allocates them cyclically). This must
            // precede the name filters, which would otherwise drop it.
            if (event->mask & IN_IGNORED) {
                for (auto it = storageWatchDescriptors_.begin();
                     it != storageWatchDescriptors_.end();) {
                    it = it->second == event->wd
                             ? storageWatchDescriptors_.erase(it)
                             : std::next(it);
                }
                watches_.erase(event->wd);
                continue;
            }
            std::string name = event->len > 0 ? event->name : "";
            const auto &[engineId, directory, kind] = watch->second;
            if (isIgnoredName(kind == WatchKind::Engine, name)) {
                continue;
            }
            if (kind == WatchKind::Root) {
                // Folder-level churn only. No IN_ISDIR gate: symlinked
                // engine folders (the dev workflow) raise these events
                // without it; the receiver reconciles against disk state,
                // so stray file names are harmless no-ops there.
                if ((event->mask & (IN_CREATE | IN_MOVED_TO | IN_DELETE |
                                    IN_MOVED_FROM)) == 0) {
                    continue;
                }
                scheduleCallback(name, directory / name, kind);
                continue;
            }
            if (kind == WatchKind::Engine && (event->mask & IN_ISDIR) &&
                !isUnwatchedDirectoryName(name)) {
                if (event->mask & (IN_CREATE | IN_MOVED_TO)) {
                    watchDirectoryTree(engineId, directory / name);
                } else if (event->mask & IN_MOVED_FROM) {
                    // A watch follows its directory, which would keep
                    // reporting from outside the engine folder.
                    unwatchDirectoryTree(directory / name);
                } else if (event->mask & IN_ATTRIB) {
                    // A chmod may open up a directory, or subdirectories of
                    // one, that the walk could not enter before.
                    watchDirectoryTree(engineId, directory / name, true);
                }
            }
            scheduleCallback(engineId, directory / name, kind);
        }
    }
}

void EngineWatcher::scheduleCallback(const std::string &engineId,
                                     const std::filesystem::path &changedPath,
                                     WatchKind kind) {
    // Editors burst several events per save; (re)arming a one-shot timer
    // coalesces them into one callback carrying every touched path.
    const char *prefix = kind == WatchKind::Storage ? "storage:"
                         : kind == WatchKind::Root  ? "root:"
                                                    : "reload:";
    std::string slot = prefix + engineId;
    pendingPaths_[slot].insert(changedPath.string());
    pending_[slot] = scheduleOneShot(
        *eventLoop_, kDebounceMicroseconds, [this, engineId, slot, kind] {
            auto changed = std::move(pendingPaths_[slot]);
            pendingPaths_.erase(slot);
            pending_.erase(slot);
            (kind == WatchKind::Storage ? storageCallback_
             : kind == WatchKind::Root  ? rootCallback_
                                        : callback_)(engineId, changed);
        });
}

} // namespace MacishType::Fcitx5
