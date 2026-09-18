#pragma once

#include <string>

namespace MacishType {

// One key event in the contract's web KeyboardEvent vocabulary
// (engines/README.md).
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

} // namespace MacishType
