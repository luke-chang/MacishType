#pragma once

#include <optional>
#include <string>

#include <fcitx-utils/key.h>

#include <MacishType/WebKeyEvent.h>

namespace MacishType::Fcitx5 {

// `rawKey` carries the layout-resolved keysym plus the X-style keycode
// (evdev + 8). Web `code` derives from the keycode alone (physical
// position); `key` from the keysym (layout-aware).
WebKeyEvent translateKeyEvent(const fcitx::Key &rawKey);

// The digit a physical digit key names — main row (`Digit1`…`Digit0`) or
// keypad (`Numpad1`…`Numpad0`) — or nullopt for any other code. The name
// carries the digit, so the lookup stays layout-independent even where the
// digit row is shifted.
std::optional<char> digitForWebCode(const std::string &code);

} // namespace MacishType::Fcitx5
