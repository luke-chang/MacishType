add_library(macishtype SHARED
    coreadapters.cpp
    enginediscovery.cpp
    enginesettings.cpp
    enginewatcher.cpp
    fontcoverage.cpp
    i18n.cpp
    iconlinks.cpp
    webkeymap.cpp
    macishtype.cpp
    session.cpp
)
target_compile_definitions(macishtype PRIVATE
    FCITX_INSTALL_LOCALEDIR="${FCITX_INSTALL_LOCALEDIR}"
    MACISHTYPE_VERSION="${PROJECT_VERSION}")
# The full version (with build stamp) is baked into a generated source at
# build time — not at configure time, so a new stamp never triggers a full
# rebuild and the CMake cache holds no stale copy. version-full.txt feeds
# CPack the same value (see cmake/cpack-version.cmake.in).
add_custom_target(versionstamp
    BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/versionstamp.cpp"
               "${CMAKE_CURRENT_BINARY_DIR}/version-full.txt"
    COMMAND "${CMAKE_COMMAND}"
        -DPROJECT_VERSION=${PROJECT_VERSION}
        "-DSTAMP_SCRIPT=${PROJECT_SOURCE_DIR}/scripts/version-stamp.sh"
        "-DOUTPUT_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        -P "${PROJECT_SOURCE_DIR}/cmake/versionstamp.cmake")
target_sources(macishtype PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/versionstamp.cpp")
add_dependencies(macishtype versionstamp)
target_link_libraries(macishtype PRIVATE Fcitx5::Core Fcitx5::Module::Notifications
    macishtype-jshost Fontconfig::Fontconfig)
install(TARGETS macishtype DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

# The runtime assets are shared across platforms and live at the repo level,
# one directory above this platform's CMake source root.
install(FILES
    "${PROJECT_SOURCE_DIR}/../runtime/hostglue.js"
    "${PROJECT_SOURCE_DIR}/../runtime/runtime.js"
    DESTINATION "${FCITX_INSTALL_PKGDATADIR}/macishtype")

configure_file(macishtype-addon.conf.in macishtype-addon.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/macishtype-addon.conf"
        RENAME macishtype.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
