#pragma once

#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <string>

#include <fcitx-utils/event.h>

#include "EngineDiscovery.h"

namespace MacishType {

// Installs engine icons into the user's hicolor theme so panels can be handed
// a theme *name* instead of a file path. SNI/dbusmenu panels (what GNOME's
// AppIndicator support drives) only accept a name in their icon field and
// render a path as a missing-icon glyph; panels that accept a path accept a
// name too, so the name is the portable choice.
//
// Every failure path falls back to the icon's absolute path, so a panel that
// takes one still renders the icon; only name-only panels lose it.
class IconLinks {
public:
    explicit IconLinks(fcitx::EventLoop *eventLoop);

    // Points macishtype-<id>[-symbolic].svg at `icon` and returns what panels
    // should be served: the theme name on success, `icon.path` otherwise.
    // Drops a previously installed entry when the engine's icon no longer
    // resolves to an SVG.
    std::string install(const std::string &engineId, const ResolvedIcon &icon);

    // Startup only, after every engine has been installed: removes the theme
    // entries this addon left behind for engines that are gone (or whose icon
    // now resolves to a different file name). Only ever deletes symlinks whose
    // names this addon creates.
    void sweepOrphans();

    // Uninstall cleanup: removes every theme entry this addon's naming owns,
    // regardless of the live engine set. Same symlink-only rule as the sweep.
    void removeAll();

private:
    // Shared walk behind sweepOrphans/removeAll: deletes our symlinks whose
    // file names are not in `keep`, returning how many went.
    size_t removeMatching(const std::set<std::string> &keep);
    bool writeLink(const std::filesystem::path &linkPath,
                   const std::string &target);
    void removeEntry(const std::string &fileName);
    // Coalesces the nudge: one refresh per burst of installs (a batch of
    // engines at startup, a reload storm) instead of one per engine.
    void scheduleRefresh();
    void refreshNow();
    // One warning per engine: a failure that repeats on every reload is noise.
    void warnOnce(const std::string &engineId, const std::string &message);

    // Empty when there is no writable user data directory, which disables the
    // whole feature (every install then returns the absolute path).
    std::filesystem::path iconsRoot_;
    std::filesystem::path appsDir_;
    // Engine id -> the theme file name currently installed for it.
    std::map<std::string, std::string> installed_;
    // Engine id -> the icon file's mtime when it was last installed. An icon
    // regenerated in place keeps its name, so only this detects that panels
    // are holding a stale image.
    std::map<std::string, std::filesystem::file_time_type> targetMtimes_;
    std::set<std::string> warned_;
    std::unique_ptr<fcitx::EventSourceTime> refreshTimer_;
    fcitx::EventLoop *eventLoop_;
};

} // namespace MacishType
