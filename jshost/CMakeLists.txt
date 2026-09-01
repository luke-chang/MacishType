cmake_minimum_required(VERSION 3.25)

# macishtype-jshost: the shared QuickJS engine host, an implementation
# detail of whichever platform component embeds a JS engine. A standalone
# project — the headless CLI and contract tests build from here — and
# equally consumable with add_subdirectory (the fcitx5 project folds it
# into the addon .so). Platform capabilities enter through the host seams
# (include/MacishType/HostSeams.h, HostEventLoop.h).
project(macishtype-jshost LANGUAGES C CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../shared/cmake/SourcePathMap.cmake")

# The embedded interpreter runs on every keystroke; never build it
# unoptimized by accident.
if(PROJECT_IS_TOP_LEVEL AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# quickjs-ng builds as a static library folded into whatever consumes this
# (a .so on Linux), so it needs PIC; EXCLUDE_FROM_ALL keeps its CLI and
# install rules out.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/external/quickjs-ng/CMakeLists.txt")
    message(FATAL_ERROR "quickjs-ng submodule is missing; run:\n"
                        "  git submodule update --init")
endif()
add_subdirectory(external/quickjs-ng EXCLUDE_FROM_ALL)

# The platform-independent pieces this host shares with native hosts.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../shared" shared EXCLUDE_FROM_ALL)

add_library(macishtype-jshost STATIC
    src/Condition.cpp
    src/EngineHost.cpp
    src/EventData.cpp
    src/FontCoverage.cpp
    src/HostSeams.cpp
    src/Intl.cpp
    src/Manifest.cpp
)
target_include_directories(macishtype-jshost PUBLIC include)
target_compile_features(macishtype-jshost PUBLIC cxx_std_20)
set_target_properties(macishtype-jshost PROPERTIES CXX_EXTENSIONS OFF)
target_link_libraries(macishtype-jshost PUBLIC qjs macishtype-shared)

# Headless CLI: the reference seam embedding, driven by the contract tests.
add_executable(macishtype-jshost-cli cli/Main.cpp)
target_link_libraries(macishtype-jshost-cli PRIVATE macishtype-jshost)
