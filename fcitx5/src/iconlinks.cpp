#include "iconlinks.h"

#include <algorithm>
#include <string_view>
#include <system_error>

#include <unistd.h>

#include <fcitx-utils/standardpaths.h>

#include "log.h"

namespace macishtype {

namespace {

constexpr std::string_view kNamePrefix = "macishtype-";
constexpr std::string_view kSymbolicSuffix = "-symbolic";

bool endsWith(const std::string &text, std::string_view suffix) {
    return text.size() >= suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// The installed file name and the name panels are served must agree exactly:
// a toolkit's fallback chain only strips trailing `-` components from the name
// it was given, it never appends `-symbolic`. So no aliases are installed.
std::string themeNameFor(const std::string &engineId, IconKind kind) {
    switch (kind) {
    case IconKind::SymbolicSvg:
        // Only a real symbolic SVG may claim this suffix: panels paint such
        // names as a flat recolored mask, which would destroy a full-color
        // icon.
        return std::string(kNamePrefix) + engineId + std::string(kSymbolicSuffix);
    case IconKind::Svg:
        return std::string(kNamePrefix) + engineId;
    case IconKind::Png:
    case IconKind::None:
        break;
    }
    // A bitmap has to live in a size-named directory (hicolor honors only its
    // fixed sizes) and an off-size or non-square PNG has no legal home at all,
    // so PNG keeps the absolute path. Engines that want an icon on every panel
    // ship SVG.
    return {};
}

std::string fileNameFor(const std::string &engineId, IconKind kind) {
    auto name = themeNameFor(engineId, kind);
    return name.empty() ? name : name + ".svg";
}

// Recognizes only the names this addon creates:
// macishtype-<id>[-symbolic].(svg|png), plus the .tmp-<pid> staging file an
// interrupted install can leave. Anything else in the directory belongs to
// someone else and is never touched — the sweep must not be able to eat a
// user's own icons.
bool isOurEntryName(const std::string &fileName) {
    if (fileName.rfind(kNamePrefix, 0) != 0) {
        return false;
    }
    std::string rest = fileName.substr(kNamePrefix.size());
    // An interrupted install stages as <final name>.tmp-<digits>.
    auto tmp = rest.rfind(".tmp-");
    if (tmp != std::string::npos) {
        std::string digits = rest.substr(tmp + 5);
        if (digits.empty() ||
            !std::all_of(digits.begin(), digits.end(),
                         [](char ch) { return ch >= '0' && ch <= '9'; })) {
            return false;
        }
        rest = rest.substr(0, tmp);
    }
    if (endsWith(rest, ".svg")) {
        rest = rest.substr(0, rest.size() - 4);
    } else if (endsWith(rest, ".png")) {
        // .png is never installed today, but a link from an older version
        // still deserves cleaning up.
        rest = rest.substr(0, rest.size() - 4);
    } else {
        return false;
    }
    if (endsWith(rest, kSymbolicSuffix)) {
        rest = rest.substr(0, rest.size() - kSymbolicSuffix.size());
    }
    return isValidEngineId(rest);
}

} // namespace

IconLinks::IconLinks(fcitx::EventLoop *eventLoop) : eventLoop_(eventLoop) {
    // Deliberately StandardPathsType::Data (~/.local/share), not PkgData: the
    // icon theme is a desktop-wide search path, not fcitx's own data.
    const auto &dataHome = fcitx::StandardPaths::global().userDirectory(
        fcitx::StandardPathsType::Data);
    if (dataHome.empty()) {
        // Documented as possible; joining onto an empty path would yield a
        // relative "icons" directory and litter fcitx5's working directory.
        MACISHTYPE_INFO() << "No user data directory; engine icons stay on "
                             "absolute paths";
        return;
    }
    iconsRoot_ = dataHome / "icons";
    // Vector icons belong in scalable/apps, which the system hicolor
    // index.theme already declares. Never write an index.theme here: a
    // toolkit takes the first one on the search path, so an incomplete copy
    // would shadow the system's and break icon lookup desktop-wide.
    appsDir_ = iconsRoot_ / "hicolor/scalable/apps";
}

std::string IconLinks::install(const std::string &engineId,
                               const ResolvedIcon &icon) {
    if (iconsRoot_.empty()) {
        return icon.path;
    }
    // An id ending in `-symbolic` would either claim the recolorable name for
    // a full-color icon or collide with the engine's own symbolic variant.
    if (endsWith(engineId, kSymbolicSuffix)) {
        warnOnce(engineId, "Engine id ends with -symbolic; serving its icon by "
                           "path instead of installing a theme entry");
        return icon.path;
    }

    const std::string desired = fileNameFor(engineId, icon.kind);
    auto previous = installed_.find(engineId);
    if (desired.empty()) {
        if (previous != installed_.end()) {
            removeEntry(previous->second);
            installed_.erase(previous);
            targetMtimes_.erase(engineId);
            scheduleRefresh();
        }
        return icon.path;
    }

    std::error_code errorCode;
    std::filesystem::create_directories(appsDir_, errorCode);
    if (errorCode) {
        warnOnce(engineId, "Cannot create " + appsDir_.string() + ": " +
                               errorCode.message());
        return icon.path;
    }

    auto linkPath = appsDir_ / desired;
    // symlink_status, never exists(): exists() follows the link, so a dangling
    // entry reads as absent and the create below would fail with EEXIST.
    auto status = std::filesystem::symlink_status(linkPath, errorCode);
    bool needsWrite = true;
    if (!errorCode) {
        if (!std::filesystem::is_symlink(status)) {
            // A real file or directory holds the name — the user's own, not
            // ours to replace.
            warnOnce(engineId, "Not a symlink, leaving it alone: " +
                                   linkPath.string());
            return icon.path;
        }
        auto target = std::filesystem::read_symlink(linkPath, errorCode);
        needsWrite = static_cast<bool>(errorCode) || target != icon.path;
    }
    if (needsWrite && !writeLink(linkPath, icon.path)) {
        warnOnce(engineId, "Cannot install icon theme entry " +
                               linkPath.string());
        return icon.path;
    }
    bool changed = needsWrite;
    // A variant switch (icon-symbolic.svg <-> icon.svg) changes the file name;
    // the stale one must go or a fallback chain could still resolve it.
    if (previous != installed_.end() && previous->second != desired) {
        removeEntry(previous->second);
        changed = true;
    }
    installed_[engineId] = desired;
    // An icon rewritten in place (a generator re-running) leaves the link
    // untouched, so the mtime is the only signal that panels are showing a
    // stale image.
    auto modified = std::filesystem::last_write_time(icon.path, errorCode);
    if (!errorCode) {
        auto remembered = targetMtimes_.find(engineId);
        if (remembered == targetMtimes_.end() || remembered->second != modified) {
            changed = true;
        }
        targetMtimes_[engineId] = modified;
    }
    if (changed) {
        scheduleRefresh();
    }
    return themeNameFor(engineId, icon.kind);
}

void IconLinks::sweepOrphans() {
    // Whatever is installed right now is what stays; deriving the keep set from
    // the live entries (rather than from the engine list) also drops the old
    // file name after an engine switched icon variants.
    std::set<std::string> keep;
    for (const auto &[engineId, fileName] : installed_) {
        keep.insert(fileName);
    }
    size_t removed = removeMatching(keep);
    if (removed != 0) {
        MACISHTYPE_INFO() << "Removed " << removed
                          << " stale icon theme entr"
                          << (removed == 1 ? "y" : "ies");
        scheduleRefresh();
    }
}

void IconLinks::removeAll() {
    size_t removed = removeMatching({});
    installed_.clear();
    targetMtimes_.clear();
    if (removed != 0) {
        MACISHTYPE_INFO() << "Removed " << removed << " icon theme entr"
                          << (removed == 1 ? "y" : "ies") << " on uninstall";
    }
}

size_t IconLinks::removeMatching(const std::set<std::string> &keep) {
    if (iconsRoot_.empty()) {
        return 0;
    }
    std::error_code errorCode;
    auto hicolor = iconsRoot_ / "hicolor";
    // Every size directory, not just scalable/: a link written by an older
    // version (or by hand) should still be cleaned up.
    std::filesystem::directory_iterator sizes(hicolor, errorCode);
    if (errorCode) {
        return 0;
    }
    size_t removed = 0;
    for (const auto &size : sizes) {
        auto apps = size.path() / "apps";
        std::filesystem::directory_iterator entries(apps, errorCode);
        if (errorCode) {
            continue;
        }
        for (const auto &entry : entries) {
            // Symlinks only. A regular file with one of our names is the
            // user's own — overriding ours is legitimate, deleting it is not.
            if (!entry.is_symlink(errorCode) || errorCode) {
                continue;
            }
            auto fileName = entry.path().filename().string();
            if (!isOurEntryName(fileName) || keep.count(fileName) != 0) {
                continue;
            }
            // remove() works on a dangling symlink, which is the common case
            // here (the engine folder it pointed at is gone).
            if (std::filesystem::remove(entry.path(), errorCode)) {
                removed++;
            } else if (errorCode) {
                MACISHTYPE_WARN() << "Cannot remove stale icon theme entry "
                                  << entry.path() << ": "
                                  << errorCode.message();
            }
        }
    }
    return removed;
}

void IconLinks::scheduleRefresh() {
    // Trailing debounce: startup installs every engine, and a reload storm can
    // reinstall several in a row. The desktop takes seconds to notice a rescan
    // anyway, so 250 ms costs nothing and collapses the burst into one nudge.
    refreshTimer_ = eventLoop_->addTimeEvent(
        CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 250000, 0,
        [this](fcitx::EventSourceTime *, uint64_t) {
            // Resetting the timer destroys the unique_ptr owning this closure;
            // touch only `self` afterwards.
            IconLinks *self = this;
            self->refreshTimer_.reset();
            self->refreshNow();
            return true;
        });
}

void IconLinks::refreshNow() {
    // Toolkits notice a new *directory* on the icon search path but not a new
    // file inside a directory they already scanned — measured: such a file is
    // never picked up on its own, and no theme-changed signal fires. Bumping
    // the search path's own mtime is what makes them rescan, after which a
    // newly linked engine icon resolves (already-drawn icons re-render too).
    // Without this a new engine would stay iconless until the next login.
    std::error_code errorCode;
    auto now = std::filesystem::file_time_type::clock::now();
    std::filesystem::last_write_time(iconsRoot_, now, errorCode);
    if (errorCode) {
        MACISHTYPE_WARN() << "Cannot touch " << iconsRoot_
                          << " to trigger an icon theme rescan: "
                          << errorCode.message();
        return;
    }
    std::filesystem::last_write_time(iconsRoot_ / "hicolor", now, errorCode);
    MACISHTYPE_INFO() << "Nudged " << iconsRoot_ << " for an icon theme rescan";
}

bool IconLinks::writeLink(const std::filesystem::path &linkPath,
                          const std::string &target) {
    // Create beside the destination and rename over it: a panel scanning the
    // directory never sees a half-written entry, and replacing an existing
    // link needs no unlink-then-create window.
    std::error_code errorCode;
    auto temporary = linkPath;
    temporary += ".tmp-" + std::to_string(getpid());
    std::filesystem::remove(temporary, errorCode);
    std::filesystem::create_symlink(target, temporary, errorCode);
    if (errorCode) {
        return false;
    }
    std::filesystem::rename(temporary, linkPath, errorCode);
    if (errorCode) {
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return false;
    }
    return true;
}

void IconLinks::removeEntry(const std::string &fileName) {
    std::error_code errorCode;
    std::filesystem::remove(appsDir_ / fileName, errorCode);
}

void IconLinks::warnOnce(const std::string &engineId,
                         const std::string &message) {
    if (warned_.insert(engineId).second) {
        MACISHTYPE_WARN() << engineId << ": " << message;
    }
}

} // namespace macishtype
