// Entry point for the shared library's self-tests. The binary links against
// nothing but macishtype-shared (whole archive) and ICU, so building it is
// also the acceptance check that this library stays consumable by a host that
// embeds no JS runtime.

#include <cstdio>

#include "Checks.h"

int main() {
    Checks checks;

    testDictionaries(checks);
    testGraphemeIndex(checks);

    if (checks.failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", checks.failures);
        return 1;
    }
    std::printf("all checks passed\n");
    return 0;
}
