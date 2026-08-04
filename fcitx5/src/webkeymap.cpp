#include "webkeymap.h"

#include <map>

#include <fcitx-utils/keysym.h>

namespace macishtype {

namespace {

// evdev code (X keycode - 8) → W3C UI Events `code`. Follows the Chromium /
// W3C keyboard tables for the writing-system, control, and numpad blocks.
const std::map<uint32_t, const char *> &evdevToWebCode() {
    static const std::map<uint32_t, const char *> table = {
        {1, "Escape"},
        {2, "Digit1"}, {3, "Digit2"}, {4, "Digit3"}, {5, "Digit4"},
        {6, "Digit5"}, {7, "Digit6"}, {8, "Digit7"}, {9, "Digit8"},
        {10, "Digit9"}, {11, "Digit0"},
        {12, "Minus"}, {13, "Equal"}, {14, "Backspace"}, {15, "Tab"},
        {16, "KeyQ"}, {17, "KeyW"}, {18, "KeyE"}, {19, "KeyR"},
        {20, "KeyT"}, {21, "KeyY"}, {22, "KeyU"}, {23, "KeyI"},
        {24, "KeyO"}, {25, "KeyP"},
        {26, "BracketLeft"}, {27, "BracketRight"}, {28, "Enter"},
        {29, "ControlLeft"},
        {30, "KeyA"}, {31, "KeyS"}, {32, "KeyD"}, {33, "KeyF"},
        {34, "KeyG"}, {35, "KeyH"}, {36, "KeyJ"}, {37, "KeyK"},
        {38, "KeyL"},
        {39, "Semicolon"}, {40, "Quote"}, {41, "Backquote"},
        {42, "ShiftLeft"}, {43, "Backslash"},
        {44, "KeyZ"}, {45, "KeyX"}, {46, "KeyC"}, {47, "KeyV"},
        {48, "KeyB"}, {49, "KeyN"}, {50, "KeyM"},
        {51, "Comma"}, {52, "Period"}, {53, "Slash"}, {54, "ShiftRight"},
        {55, "NumpadMultiply"}, {56, "AltLeft"}, {57, "Space"},
        {58, "CapsLock"},
        {59, "F1"}, {60, "F2"}, {61, "F3"}, {62, "F4"}, {63, "F5"},
        {64, "F6"}, {65, "F7"}, {66, "F8"}, {67, "F9"}, {68, "F10"},
        {69, "NumLock"}, {70, "ScrollLock"},
        {71, "Numpad7"}, {72, "Numpad8"}, {73, "Numpad9"},
        {74, "NumpadSubtract"},
        {75, "Numpad4"}, {76, "Numpad5"}, {77, "Numpad6"},
        {78, "NumpadAdd"},
        {79, "Numpad1"}, {80, "Numpad2"}, {81, "Numpad3"},
        {82, "Numpad0"}, {83, "NumpadDecimal"},
        {85, "Lang5"}, {86, "IntlBackslash"}, {87, "F11"}, {88, "F12"},
        {89, "IntlRo"}, {90, "Lang3"}, {91, "Lang4"}, {92, "Convert"},
        {93, "KanaMode"}, {94, "NonConvert"},
        {96, "NumpadEnter"}, {97, "ControlRight"}, {98, "NumpadDivide"},
        {99, "PrintScreen"}, {100, "AltRight"},
        {102, "Home"}, {103, "ArrowUp"}, {104, "PageUp"},
        {105, "ArrowLeft"}, {106, "ArrowRight"}, {107, "End"},
        {108, "ArrowDown"}, {109, "PageDown"}, {110, "Insert"},
        {111, "Delete"},
        {113, "AudioVolumeMute"}, {114, "AudioVolumeDown"},
        {115, "AudioVolumeUp"},
        {117, "NumpadEqual"}, {119, "Pause"}, {121, "NumpadComma"},
        {122, "Lang1"}, {123, "Lang2"}, {124, "IntlYen"},
        {125, "MetaLeft"}, {126, "MetaRight"}, {127, "ContextMenu"},
        {183, "F13"}, {184, "F14"}, {185, "F15"}, {186, "F16"},
        {187, "F17"}, {188, "F18"}, {189, "F19"}, {190, "F20"},
        {191, "F21"}, {192, "F22"}, {193, "F23"}, {194, "F24"},
    };
    return table;
}

// Non-printable keysyms → web `key` named values.
const std::map<uint32_t, const char *> &keysymToWebKeyName() {
    static const std::map<uint32_t, const char *> table = {
        {FcitxKey_Return, "Enter"},
        {FcitxKey_KP_Enter, "Enter"},
        {FcitxKey_ISO_Enter, "Enter"},
        {FcitxKey_Tab, "Tab"},
        {FcitxKey_ISO_Left_Tab, "Tab"},
        {FcitxKey_BackSpace, "Backspace"},
        {FcitxKey_Escape, "Escape"},
        {FcitxKey_Delete, "Delete"},
        {FcitxKey_KP_Delete, "Delete"},
        {FcitxKey_Insert, "Insert"},
        {FcitxKey_KP_Insert, "Insert"},
        {FcitxKey_Home, "Home"},
        {FcitxKey_KP_Home, "Home"},
        {FcitxKey_End, "End"},
        {FcitxKey_KP_End, "End"},
        {FcitxKey_Page_Up, "PageUp"},
        {FcitxKey_KP_Page_Up, "PageUp"},
        {FcitxKey_Page_Down, "PageDown"},
        {FcitxKey_KP_Page_Down, "PageDown"},
        {FcitxKey_Left, "ArrowLeft"},
        {FcitxKey_KP_Left, "ArrowLeft"},
        {FcitxKey_Right, "ArrowRight"},
        {FcitxKey_KP_Right, "ArrowRight"},
        {FcitxKey_Up, "ArrowUp"},
        {FcitxKey_KP_Up, "ArrowUp"},
        {FcitxKey_Down, "ArrowDown"},
        {FcitxKey_KP_Down, "ArrowDown"},
        {FcitxKey_KP_Begin, "Clear"},
        {FcitxKey_Clear, "Clear"},
        {FcitxKey_Shift_L, "Shift"},
        {FcitxKey_Shift_R, "Shift"},
        {FcitxKey_Control_L, "Control"},
        {FcitxKey_Control_R, "Control"},
        {FcitxKey_Alt_L, "Alt"},
        {FcitxKey_Alt_R, "Alt"},
        {FcitxKey_Meta_L, "Meta"},
        {FcitxKey_Meta_R, "Meta"},
        {FcitxKey_Super_L, "Meta"},
        {FcitxKey_Super_R, "Meta"},
        {FcitxKey_Caps_Lock, "CapsLock"},
        {FcitxKey_Num_Lock, "NumLock"},
        {FcitxKey_Scroll_Lock, "ScrollLock"},
        {FcitxKey_Menu, "ContextMenu"},
        {FcitxKey_Print, "PrintScreen"},
        {FcitxKey_Pause, "Pause"},
        {FcitxKey_ISO_Level3_Shift, "AltGraph"},
        {FcitxKey_Mode_switch, "AltGraph"},
        {FcitxKey_Muhenkan, "NonConvert"},
        {FcitxKey_Henkan_Mode, "Convert"},
        {FcitxKey_Hiragana_Katakana, "HiraganaKatakana"},
        {FcitxKey_Zenkaku_Hankaku, "ZenkakuHankaku"},
    };
    return table;
}

// Control characters macOS reports for named keys in
// `keyIgnoringModifiers`; everything else falls back to `key`.
const char *controlCharForKeysym(uint32_t keysym) {
    switch (keysym) {
    case FcitxKey_Tab:
    case FcitxKey_ISO_Left_Tab:
        return "\t";
    case FcitxKey_Return:
    case FcitxKey_KP_Enter:
        return "\r";
    case FcitxKey_Escape:
        return "\x1b";
    case FcitxKey_BackSpace:
        return "\x7f";
    default:
        return nullptr;
    }
}

int locationForKey(const fcitx::Key &key) {
    uint32_t keysym = static_cast<uint32_t>(key.sym());
    if (keysym >= FcitxKey_KP_Space && keysym <= FcitxKey_KP_9) {
        return 3;
    }
    switch (keysym) {
    case FcitxKey_Shift_L:
    case FcitxKey_Control_L:
    case FcitxKey_Alt_L:
    case FcitxKey_Meta_L:
    case FcitxKey_Super_L:
        return 1;
    case FcitxKey_Shift_R:
    case FcitxKey_Control_R:
    case FcitxKey_Alt_R:
    case FcitxKey_Meta_R:
    case FcitxKey_Super_R:
        return 2;
    default:
        return 0;
    }
}

} // namespace

WebKeyEvent translateKeyEvent(const fcitx::Key &rawKey) {
    WebKeyEvent event;
    auto states = rawKey.states();
    event.shiftKey = states.test(fcitx::KeyState::Shift);
    event.ctrlKey = states.test(fcitx::KeyState::Ctrl);
    event.altKey = states.test(fcitx::KeyState::Alt);
    event.metaKey = states.test(fcitx::KeyState::Super) ||
                    states.test(fcitx::KeyState::Super2);
    event.capsLock = states.test(fcitx::KeyState::CapsLock);
    // KeyState::NumLock is Mod2, where the common XKB maps bind the lock. A
    // frontend may still not forward it.
    event.numLock = states.test(fcitx::KeyState::NumLock);
    event.repeat = states.test(fcitx::KeyState::Repeat);
    event.location = locationForKey(rawKey);

    uint32_t keycode = rawKey.code();
    if (keycode >= 8) {
        const auto &codes = evdevToWebCode();
        if (auto found = codes.find(keycode - 8); found != codes.end()) {
            event.code = found->second;
        }
    }

    auto keysym = static_cast<uint32_t>(rawKey.sym());
    const auto &names = keysymToWebKeyName();
    if (auto found = names.find(keysym); found != names.end()) {
        event.key = found->second;
    } else {
        std::string character =
            fcitx::Key::keySymToUTF8(rawKey.sym());
        event.key = character.empty() ? "Unidentified" : character;
    }

    // macOS strips Option's layout transformation here; X keysyms are not
    // transformed by plain Alt, so the produced character already matches.
    if (const char *control = controlCharForKeysym(keysym)) {
        event.keyIgnoringModifiers = control;
    } else {
        event.keyIgnoringModifiers = event.key;
    }

    return event;
}

} // namespace macishtype
