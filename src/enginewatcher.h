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
    // changes inside a storage directory armed via watchStorage.
    EngineWatcher(fcitx::EventLoop *eventLoop, Callback callback,
                  Callback storageCallback);
    ~EngineWatcher();
    EngineWatcher(const EngineWatcher &) = delete;
    EngineWatcher &operator=(const EngineWatcher &) = delete;

    // Idempotent; re-watching an engine refreshes its directory set.
    void watchEngine(const std::string &engineId,
                     const std::filesystem::path &root);

    // Storage watches are armed on demand (the engine has `storage`
    // listeners) and flat — key files only, no subdirectories. Creates
    // the directory when missing, since inotify needs it to exist.
    void watchStorage(const std::string &engineId,
                      const std::filesystem::path &directory);
    void unwatchStorage(const std::string &engineId);

private:
    struct Watch {
        std::string engineId;
        std::filesystem::path directory;
        bool storage = false;
    };

    void watchDirectoryTree(const std::string &engineId,
                            const std::filesystem::path &directory);
    void handleEvents();
    void scheduleCallback(const std::string &engineId,
                          const std::filesystem::path &changedPath,
                          bool storage);

    fcitx::EventLoop *eventLoop_;
    Callback callback_;
    Callback storageCallback_;
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
