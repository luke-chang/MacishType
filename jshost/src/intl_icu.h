#pragma once

// Single include/link isolation point for ICU. The ICU C API
// (ubrk_/udat_/ucal_/udatpg_/unumf_/ucol_/uplrules_/uloc_) is identical across
// platforms — only this header differs, so every call site in intl.cpp stays
// byte-for-byte portable. The Windows system icu.dll exports unversioned
// symbols, so U_DISABLE_RENAMING must precede the combined <icu.h> (the
// formatter APIs used here need Windows 10 1903+, ICU 64); elsewhere —
// including a vcpkg ICU on Windows — the conventional per-component headers
// apply. The CMake build always takes the per-component branch; a build that
// links the system icu.dll must define MACISHTYPE_ICU_WINDOWS_SYSTEM itself.
#if defined(MACISHTYPE_ICU_WINDOWS_SYSTEM)
#define U_DISABLE_RENAMING 1
#include <icu.h>
#else
#include <unicode/utypes.h>
#include <unicode/uenum.h>
#include <unicode/ustring.h>
#include <unicode/utext.h>
#include <unicode/uloc.h>
#include <unicode/ubrk.h>
#include <unicode/ucal.h>
#include <unicode/udat.h>
#include <unicode/udatpg.h>
#include <unicode/unum.h>
#include <unicode/unumberformatter.h>
#include <unicode/unumsys.h>
#include <unicode/ucol.h>
#include <unicode/upluralrules.h>
#include <unicode/ufieldpositer.h>
#endif
