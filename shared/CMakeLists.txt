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
    src/RefCountedDictionary.cpp
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

# Only when shared/ is configured on its own: this is the acceptance check
# that a host embedding no JS runtime can still consume the library, so it
# deliberately never rides along with the fcitx5 or jshost builds.
if(PROJECT_IS_TOP_LEVEL)
    enable_testing()
    add_executable(macishtype-shared-test tests/DictionaryTests.cpp)
    # WHOLE_ARCHIVE is what makes this equivalent to the manual "link
    # libmacishtype-shared.a plus ICU and nothing else" check: a plain link
    # would pull in only the members the test happens to reference, letting a
    # new source file take a jshost/seam/QuickJS dependency unnoticed.
    target_link_libraries(macishtype-shared-test
        PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,macishtype-shared>")
    add_test(NAME dictionaries COMMAND macishtype-shared-test)
endif()
