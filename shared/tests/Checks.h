#pragma once

#include <cstdio>

struct Checks {
    int failures = 0;

    void expect(bool ok, const char *what) {
        if (!ok) {
            std::fprintf(stderr, "FAIL: %s\n", what);
            ++failures;
        }
    }
};

void testDictionaries(Checks &checks);
void testGraphemeIndex(Checks &checks);
