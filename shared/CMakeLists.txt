cmake_minimum_required(VERSION 3.25)

# macishtype-shared: the platform-independent pieces every MacishType host
# needs whether or not it embeds a JS engine — the log facade, the ICU
# grapheme/Intl handle cache, UTF-8 validation, and the associated-phrase
# dictionary. Deliberately free of any JS runtime dependency so a native
# host can link it without pulling in QuickJS.
project(macishtype-shared LANGUAGES CXX)

# Applied here rather than per-project: this is the innermost of the three
# CMake projects, so every build reaches it.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/SourcePathMap.cmake")

add_library(macishtype-shared STATIC
    src/AssociatedDictionary.cpp
    src/IntlCache.cpp
    src/Log.cpp
    src/Utf8.cpp
)
target_include_directories(macishtype-shared PUBLIC include)
target_compile_features(macishtype-shared PUBLIC cxx_std_20)
set_target_properties(macishtype-shared PROPERTIES CXX_EXTENSIONS OFF)
# Folded into the fcitx5 addon .so, so everything under it needs PIC.
set_target_properties(macishtype-shared PROPERTIES POSITION_INDEPENDENT_CODE ON)

# System ICU backs grapheme segmentation and the Intl handle cache; we link
# the system library rather than bundling CLDR data. PUBLIC because
# IntlIcu.h is a public header — linking this target is what makes it the
# single ICU include/link isolation point it claims to be.
find_package(ICU REQUIRED COMPONENTS i18n uc)
target_link_libraries(macishtype-shared PUBLIC ICU::i18n ICU::uc)
