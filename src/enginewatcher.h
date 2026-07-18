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

    EngineWatcher(fcitx::EventLoop *eventLoop, Callback callback);
    ~EngineWatcher();
    EngineWatcher(const EngineWatcher &) = delete;
    EngineWatcher &operator=(const EngineWatcher &) = delete;

    // Idempotent; re-watching an engine refreshes its directory set.
    void watchEngine(const std::string &engineId,
                     const std::filesystem::path &root);

private:
    void watchDirectoryTree(const std::string &engineId,
                            const std::filesystem::path &directory);
    void handleEvents();
    void scheduleCallback(const std::string &engineId,
                          const std::filesystem::path &changedPath);

    fcitx::EventLoop *eventLoop_;
    Callback callback_;
    int inotifyFd_ = -1;
    std::unique_ptr<fcitx::EventSourceIO> ioSource_;
    // watch descriptor → (engine id, directory)
    std::map<int, std::pair<std::string, std::filesystem::path>> watches_;
    std::map<std::string, std::unique_ptr<fcitx::EventSourceTime>> pending_;
    // Paths accumulated while an engine's debounce timer is armed.
    std::map<std::string, std::set<std::string>> pendingPaths_;
};

} // namespace macishtype
