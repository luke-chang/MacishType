#pragma once

namespace MacishType {

// Half-open range of the full candidate list the current index labels
// address; both zero when no candidate window is visible.
struct PageRange {
    int start = 0;
    int end = 0;
};

} // namespace MacishType
