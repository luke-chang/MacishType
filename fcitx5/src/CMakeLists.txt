add_library(macishtype SHARED
    CoreAdapters.cpp
    EngineDiscovery.cpp
    EngineSettings.cpp
    EngineWatcher.cpp
    FontCoverage.cpp
    I18n.cpp
    IconLinks.cpp
    WebKeyMap.cpp
    MacishType.cpp
    Session.cpp
)
target_compile_definitions(macishtype PRIVATE
    FCITX_INSTALL_LOCALEDIR="${FCITX_INSTALL_LOCALEDIR}"
    MACISHTYPE_VERSION="${PROJECT_VERSION}")
# The full version (with build stamp) is baked into a generated source at
# build time — not at configure time, so a new stamp never triggers a full
# rebuild and the CMake cache holds no stale copy. VersionFull.txt feeds
# CPack the same value (see cmake/CPackVersion.cmake.in).
add_custom_target(versionstamp
    BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/VersionStamp.cpp"
               "${CMAKE_CURRENT_BINARY_DIR}/VersionFull.txt"
    COMMAND "${CMAKE_COMMAND}"
        -DPROJECT_VERSION=${PROJECT_VERSION}
        "-DSTAMP_SCRIPT=${PROJECT_SOURCE_DIR}/scripts/VersionStamp.sh"
        "-DOUTPUT_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        -P "${PROJECT_SOURCE_DIR}/cmake/VersionStamp.cmake")
target_sources(macishtype PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/VersionStamp.cpp")
add_dependencies(macishtype versionstamp)
target_link_libraries(macishtype PRIVATE Fcitx5::Core Fcitx5::Module::Notifications
    macishtype-jshost Fontconfig::Fontconfig)
install(TARGETS macishtype DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

# The shared runtime scripts live beside the libraries that own them:
# globals.js is contract-level and shared by every host, hostglue.js only
# serves QuickJS hosts. Both install into one directory, which is where
# locateRuntimeScript() looks.
install(FILES
    "${PROJECT_SOURCE_DIR}/../jshost/js/hostglue.js"
    "${PROJECT_SOURCE_DIR}/../shared/js/globals.js"
    DESTINATION "${FCITX_INSTALL_PKGDATADIR}/macishtype")

configure_file(macishtype-addon.conf.in macishtype-addon.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/macishtype-addon.conf"
        RENAME macishtype.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
