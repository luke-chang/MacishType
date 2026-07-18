#pragma once

#include <string>

namespace macishtype {

// Base64 CharacterSet bitmap (plane 0 first, then plane-number + bitmap per
// extra plane; LSB-first bits) of every codepoint some installed font can
// render, per fontconfig. Computed once and cached for the process; falls
// back to full coverage when fontconfig fails, so filtering never hides
// everything.
const std::string &fontCoverageBitmapBase64();

} // namespace macishtype
