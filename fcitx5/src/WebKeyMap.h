#pragma once

#include <optional>
#include <string>

#include <fcitx-utils/key.h>

namespace MacishType {

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
    bool numLock = false;
    bool altGraph = false;
    bool repeat = false;
    // 0 standard, 1 left modifier, 2 right modifier, 3 numpad.
    int location = 0;
};

// `rawKey` carries the layout-resolved keysym plus the X-style keycode
// (evdev + 8). Web `code` derives from the keycode alone (physical
// position); `key` from the keysym (layout-aware).
WebKeyEvent translateKeyEvent(const fcitx::Key &rawKey);

// The digit a physical digit key names — main row (`Digit1`…`Digit0`) or
// keypad (`Numpad1`…`Numpad0`) — or nullopt for any other code. The name
// carries the digit, so the lookup stays layout-independent even where the
// digit row is shifted.
std::optional<char> digitForWebCode(const std::string &code);

} // namespace MacishType
