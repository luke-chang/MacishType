cmake_minimum_required(VERSION 3.25)

# macishtype-shared: the platform-independent pieces every MacishType host
# needs whether or not it embeds a JS engine — the log facade, the ICU
# grapheme/Intl handle cache, UTF-8 validation, and the associated-phrase
# dictionary. Deliberately free of any JS runtime dependency so a native
# host can link it without pulling in QuickJS.
project(macishtype-shared LANGUAGES CXX)

# Keep the build machine's directory layout out of the artifacts: __FILE__,
# std::source_location and debug info all record whatever path the compiler
# was handed, which for an out-of-tree CMake build is absolute. Mapping the
# repo root makes them relative, so a shipped package carries no trace of
# where it was built.
get_filename_component(MACISHTYPE_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.."
                       ABSOLUTE)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options("-ffile-prefix-map=${MACISHTYPE_REPO_ROOT}=.")
endif()

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
# the system library rather than bundling CLDR data.
find_package(ICU REQUIRED COMPONENTS i18n uc)
target_link_libraries(macishtype-shared PRIVATE ICU::i18n ICU::uc)
