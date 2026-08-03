#pragma once

#include <string>

#include <fcitx-utils/key.h>

namespace macishtype {

// A fcitx key event translated into the web KeyboardEvent shape the
// MacishType JS contract uses.
struct WebKeyEvent {
    std::string key;
    std::string code;
    std::string keyIgnoringModifiers;
    bool shiftKey = false;
    bool ctrlKey = false;
    bool altKey = false;
    bool metaKey = false;
    bool capsLock = false;
    bool repeat = false;
    // 0 standard, 1 left modifier, 2 right modifier, 3 numpad.
    int location = 0;
};

// `rawKey` carries the layout-resolved keysym plus the X-style keycode
// (evdev + 8). Web `code` derives from the keycode alone (physical
// position); `key` from the keysym (layout-aware).
WebKeyEvent translateKeyEvent(const fcitx::Key &rawKey);

} // namespace macishtype
