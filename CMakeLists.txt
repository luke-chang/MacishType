cmake_minimum_required(VERSION 3.16)
project(fcitx5-macishtype VERSION 0.1.0)

find_package(Fcitx5Core REQUIRED)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")

# quickjs-ng builds as a static library folded into the addon .so, so it
# needs PIC; EXCLUDE_FROM_ALL keeps its CLI and install rules out.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/quickjs-ng EXCLUDE_FROM_ALL)

add_subdirectory(src)
