#pragma once

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>

#include <fcitx-utils/event.h>

namespace macishtype {

// inotify watcher over engine folders. File changes fire the callback once
// per engine after a short debounce, carrying the affected canonical paths
// so the reload policy can scope its reaction; `_storage/` traffic and
// editor droppings are ignored. Watches the resolved folder, so symlinked
// engine folders (the dev workflow) see edits at the link target.
class EngineWatcher {
public:
    using Callback = std::function<void(
        const std::string &engineId, const std::set<std::string> &changed)>;

    // `callback` serves reload decisions; `storageCallback` receives
    // changes inside a storage directory armed via watchStorage;
    // `rootCallback` receives folder-level churn inside an engines root
    // armed via watchEnginesRoot (first argument is the folder name).
    EngineWatcher(fcitx::EventLoop *eventLoop, Callback callback,
                  Callback storageCallback, Callback rootCallback);
    ~EngineWatcher();
    EngineWatcher(const EngineWatcher &) = delete;
    EngineWatcher &operator=(const EngineWatcher &) = delete;

    // Idempotent; re-watching an engine refreshes its directory set.
    void watchEngine(const std::string &engineId,
                     const std::filesystem::path &root);

    // Watches an engines parent directory (one XDG layer) for folders
    // appearing and vanishing. Flat, non-recursive; the directory must
    // exist. Receivers reconcile against disk state, so events are not
    // typed and symlinked folders (no IN_ISDIR) count too.
    void watchEnginesRoot(const std::filesystem::path &directory);

    // Storage watches are armed on demand (the engine has `storage`
    // listeners) and flat — key files only, no subdirectories. Creates
    // the directory when missing, since inotify needs it to exist.
    void watchStorage(const std::string &engineId,
                      const std::filesystem::path &directory);
    void unwatchStorage(const std::string &engineId);

private:
    // Which stream a watch feeds: engine trees debounce into the reload
    // callback, storage dirs into the storage callback, and engines roots
    // (keyed by folder name, empty engineId) into the root callback.
    enum class WatchKind { Engine, Storage, Root };

    struct Watch {
        std::string engineId;
        std::filesystem::path directory;
        WatchKind kind = WatchKind::Engine;
    };

    void watchDirectoryTree(const std::string &engineId,
                            const std::filesystem::path &directory);
    void handleEvents();
    void scheduleCallback(const std::string &engineId,
                          const std::filesystem::path &changedPath,
                          WatchKind kind);

    fcitx::EventLoop *eventLoop_;
    Callback callback_;
    Callback storageCallback_;
    Callback rootCallback_;
    int inotifyFd_ = -1;
    std::unique_ptr<fcitx::EventSourceIO> ioSource_;
    std::map<int, Watch> watches_;
    std::map<std::string, int> storageWatchDescriptors_;
    // Debounce timers and their accumulated paths, keyed by engine id
    // with a reload/storage prefix so the two streams stay separate.
    std::map<std::string, std::unique_ptr<fcitx::EventSourceTime>> pending_;
    std::map<std::string, std::set<std::string>> pendingPaths_;
};

} // namespace macishtype
